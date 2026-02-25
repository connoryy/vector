#!/usr/bin/env python3
"""
collapse-bpftrace.py — convert bpftrace @stacks map output to inferno folded format.

bpftrace prints the @stacks map on exit in this format:

    @stacks[
            innermost_frame
            middle_frame
            outermost_frame
    , component_id]: count

inferno expects folded format (outermost → innermost, semicolon-separated):

    component_id;outermost_frame;middle_frame;innermost_frame count

Frames with an empty component_id (threads not inside a component span) are
prefixed with "unknown" so they appear in the flamegraph as a distinct root.

Usage:
    python3 collapse-bpftrace.py bpftrace-stacks.txt > stacks-labeled.folded
    inferno-flamegraph stacks-labeled.folded > flamegraph-labeled.svg
"""

import sys
import re


def clean_frame(frame: str) -> str:
    """Strip leading address offsets that bpftrace sometimes prepends."""
    # bpftrace may emit "0xdeadbeef function_name+0x10" — keep just the name part
    frame = frame.strip()
    # Remove hex address prefix if present: "0x... "
    frame = re.sub(r'^0x[0-9a-fA-F]+\s+', '', frame)
    # Remove trailing "+0x..." offset
    frame = re.sub(r'\+0x[0-9a-fA-F]+$', '', frame)
    return frame.strip() or '[unknown]'


def parse_bpftrace_stacks(text: str):
    """
    Parse bpftrace @stacks map text output.

    Yields (component_id, frames_innermost_first, count) tuples.
    frames_innermost_first: list of frame strings, index 0 = innermost (leaf).
    """
    # Each map entry looks like:
    #
    # @stacks[
    #         frame1      <- innermost
    #         frame2
    #         frameN      <- outermost
    # , component_id]: count
    #
    # We parse by scanning for the opening "@stacks[" line, collecting frames
    # until the closing ", ...]: count" line.

    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()

        if line.strip() == '@stacks[':
            frames = []
            i += 1
            # Collect frame lines until the closing ", component]: count" line
            while i < len(lines):
                inner = lines[i].rstrip()
                # Closing line pattern: ", component_id]: count" or "]: count" (empty component)
                closing = re.match(r'^,\s*(.*)\]:\s*(\d+)\s*$', inner)
                if closing:
                    component_id = closing.group(1).strip()
                    count = int(closing.group(2))
                    yield component_id, frames, count
                    i += 1
                    break
                else:
                    frame = inner.strip()
                    if frame:
                        frames.append(clean_frame(frame))
                    i += 1
        else:
            i += 1


def to_folded(component_id: str, frames_innermost_first: list, count: int) -> str:
    """
    Convert one stack entry to a single inferno folded-stack line.

    inferno expects: root;...;leaf count
    - root = component_id (or "unknown" if empty)
    - frames reversed so outermost is leftmost
    """
    root = component_id if component_id else 'unknown'
    # frames_innermost_first[0] = leaf, [-1] = outermost caller
    # inferno wants outermost → innermost (left to right)
    ordered = list(reversed(frames_innermost_first))
    stack = ';'.join([root] + ordered)
    return f'{stack} {count}'


def main():
    if len(sys.argv) < 2:
        print('Usage: collapse-bpftrace.py <bpftrace-stacks.txt>', file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    try:
        with open(input_path) as f:
            text = f.read()
    except OSError as e:
        print(f'Error reading {input_path}: {e}', file=sys.stderr)
        sys.exit(1)

    count = 0
    for component_id, frames, n in parse_bpftrace_stacks(text):
        if frames:
            print(to_folded(component_id, frames, n))
            count += 1

    print(f'collapse-bpftrace.py: wrote {count} stack entries', file=sys.stderr)


if __name__ == '__main__':
    main()
