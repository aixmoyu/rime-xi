#!/usr/bin/env python3
"""Build weighted key tries for mobile neighbor correction from Rime dictionary files."""

import argparse
from collections import defaultdict
from functools import lru_cache
from heapq import nlargest
from math import log
from pathlib import Path
import re
import struct
from tempfile import TemporaryDirectory
import unicodedata


RIME = Path(__file__).resolve().parents[1] / "oh-my-rime"
SOURCES = [RIME / "dicts/rime_mint.base.dict.yaml"]
MAX_LENGTH = 18
MAX_WORD_LENGTH = 4
T9 = str.maketrans("abcdefghijklmnopqrstuvwxyz", "22233344455566677778889999")
PINYIN = re.compile(r"[a-z]+")
CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\U00020000-\U000323af]+")


@lru_cache(maxsize=4096)
def normalize(syllable):
    decomposed = unicodedata.normalize("NFD", syllable.lower())
    plain = decomposed.replace("u\N{COMBINING DIAERESIS}", "v")
    plain = "".join(char for char in plain if not unicodedata.combining(char))
    if plain == "ng":
        return "eng"
    return plain if PINYIN.fullmatch(plain) and plain != "xx" else ""


def read_entries(paths):
    for path in paths:
        with path.open(encoding="utf-8-sig") as source:
            for line in source:
                if line.strip() == "...":
                    break
            else:
                raise ValueError(f"missing dictionary header terminator in {path}")

            for line in source:
                if line.startswith("#"):
                    continue
                fields = line.rstrip("\r\n").split("\t")
                if len(fields) < 3:
                    continue
                word, spelling, raw_weight = fields[:3]
                try:
                    weight = int(raw_weight)
                except ValueError:
                    continue
                if weight <= 0 or len(word) > MAX_WORD_LENGTH or not CJK.fullmatch(word):
                    continue
                syllables = tuple(normalize(s.split(";", 1)[0]) for s in spelling.split())
                if not 1 <= len(syllables) <= MAX_WORD_LENGTH or not all(syllables):
                    continue
                if 2 <= sum(map(len, syllables)) <= MAX_LENGTH:
                    yield weight, syllables


class Node:
    __slots__ = ("key", "children", "prefix", "terminal")

    def __init__(self, key):
        self.key = key
        self.children = {}
        self.prefix = 0
        self.terminal = 0


def write_index(output, layout, entries):
    weights = defaultdict(int)
    for weight, syllables in entries:
        if layout == "t9":
            syllables = tuple({"m": "me", "n": "en"}.get(s, s) for s in syllables)
        code = "".join(syllables)
        if layout == "t9":
            code = code.translate(T9)
        if len(code) <= MAX_LENGTH:
            weights[code] += weight
    if not weights:
        raise ValueError(f"no usable {layout} entries")

    root = Node(0)
    for code, weight in sorted(weights.items()):
        node = root
        node.prefix += weight
        for key in code.encode("ascii"):
            if key not in node.children:
                node.children[key] = Node(key)
            node = node.children[key]
            node.prefix += weight
        node.terminal += weight

    def score(weight):
        # Zero means absent. Otherwise one unit is 1/8 of a natural log.
        return max(1, 255 + round(8 * log(weight / root.prefix))) if weight else 0

    nodes = [root]
    records = bytearray()
    for node in nodes:
        # Breadth first: children occupy the range between this node's
        # first-child pointer and the next node's pointer.
        records.extend(len(nodes).to_bytes(3, "little"))
        records.extend(struct.pack("BBB", node.key, score(node.prefix), score(node.terminal)))
        nodes.extend(node.children.values())
    records.extend(len(nodes).to_bytes(3, "little"))

    path = output / f"{layout}.bin"
    with path.open("wb") as result:
        result.write(f"RIME-KEY-TRIE-1\t{layout}\n".encode("ascii"))
        result.write(records)
    return len(nodes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dictionary", type=Path, nargs="*", default=SOURCES)
    parser.add_argument("--output-dir", type=Path, default=RIME / "lua/key_correction_data")
    parser.add_argument("--max-entries", type=int, default=100_000)
    args = parser.parse_args()
    if args.max_entries < 1:
        parser.error("--max-entries must be positive")
    entries = nlargest(args.max_entries, read_entries(args.dictionary))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=args.output_dir) as staging_dir:
        staging = Path(staging_dir)
        counts = {
            layout: write_index(staging, layout, entries)
            for layout in ("qwerty", "t9")
        }
        for layout, count in counts.items():
            filename = f"{layout}.bin"
            path = args.output_dir / filename
            (staging / filename).replace(path)
            print(f"{path}: {count:,} nodes, {path.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
