#!/usr/bin/env python3
"""Drop appcast items whose enclosure URL a newer item also claims.

WHY THIS EXISTS
---------------
The DMG name carries only the marketing version (`Clingfy_1.0.7.dmg`), but
`sparkle:version` is the Azure build id, which changes on every run. So when a
version is published twice -- the deliberate `ALLOW_OVERWRITE` path -- the blob
is replaced while the OLD appcast item survives, because `generate_appcast`
sees 775 and 776 as two different versions and preserves both.

The result is an item whose `sparkle:edSignature` was cut for bytes that no
longer exist at the URL it points to. Sparkle picks the highest version, so
updates keep working and the damage is latent -- which is exactly why it
shipped twice unnoticed (1.0.6 went out as 618+619, 1.0.7 as 775+776). But an
appcast that contains an entry which CANNOT pass signature verification is a
loaded gun: anything that selects by shortVersionString rather than by
sparkle:version, now or later, gets a hard verification failure.

Invariant restored here: one URL, one item -- the newest.

WHY TEXT SURGERY AND NOT AN XML REWRITE
---------------------------------------
Round-tripping through an XML library would reformat the whole file and, worse,
turn the CDATA-wrapped release notes that `--embed-release-notes` produces into
escaped entities. Semantically equivalent, but it rewrites every byte of every
item to fix a problem in one of them. Items are flat and never nested, so the
kept ones are copied through verbatim and only whole `<item>...</item>` spans
are removed.
"""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET

ITEM_RE = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.DOTALL)
ROOT_OPEN_RE = re.compile(r"<rss\b[^>]*>")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FALLBACK_ROOT = f'<rss xmlns:sparkle="{SPARKLE_NS}">'


def root_wrapper(xml_text: str) -> str:
    """The document's own `<rss ...>` open tag, for re-parsing lone items.

    An `<item>` lifted out of the document does NOT parse on its own: it uses
    the `sparkle:` prefix, which is declared on the root, so ElementTree raises
    "unbound prefix" and every item looks unreadable. That failure is silent in
    the worst way -- unreadable items are deliberately kept, so the pruner
    becomes a no-op that reports success. It did exactly that on first run.
    Wrapping each item in the real root tag carries every declared namespace,
    whatever they are, instead of hardcoding a guess.
    """
    match = ROOT_OPEN_RE.search(xml_text)
    return match.group(0) if match else FALLBACK_ROOT


def parse_item(item_xml: str, wrapper: str) -> ET.Element | None:
    try:
        return ET.fromstring(f"{wrapper}{item_xml}</rss>").find("item")
    except ET.ParseError:
        return None


def enclosure_url(item: ET.Element | None) -> str | None:
    """The item's enclosure URL, or None when it has no parsable enclosure."""
    if item is None:
        return None
    enclosure = item.find("enclosure")
    if enclosure is None:
        return None
    return enclosure.get("url")


def sparkle_version(item: ET.Element | None) -> int | None:
    """The item's sparkle:version as an int, or None when absent/non-numeric.

    Sparkle allows it either as an element or as an enclosure attribute; both
    are read, element first, because that is what generate_appcast emits here.
    """
    if item is None:
        return None
    node = item.find(f"{{{SPARKLE_NS}}}version")
    raw = node.text if node is not None and node.text else None
    if raw is None:
        enclosure = item.find("enclosure")
        if enclosure is not None:
            raw = enclosure.get(f"{{{SPARKLE_NS}}}version")
    if raw is None:
        return None
    try:
        return int(raw.strip())
    except ValueError:
        return None


def prune(xml_text: str) -> tuple[str, list[str]]:
    """Return (pruned_xml, messages). Only whole items are removed."""
    items = [m for m in ITEM_RE.finditer(xml_text)]
    if not items:
        return xml_text, []

    wrapper = root_wrapper(xml_text)
    parsed = [parse_item(m.group(0), wrapper) for m in items]

    # A pruner that cannot read ANY item is broken, not finished. Without this
    # it reports "nothing to prune" and exits 0 -- which is what the namespace
    # bug did, and what would happen again if the feed's shape changed.
    messages: list[str] = []
    if all(item is None for item in parsed):
        messages.append(
            f"ERROR {len(items)} item(s) found but none could be parsed -- "
            f"refusing to report a clean appcast"
        )
        return xml_text, messages

    # Group item indices by enclosure URL. Items without a URL are never
    # candidates for removal -- an item we cannot read is an item we leave.
    by_url: dict[str, list[int]] = {}
    for idx, item in enumerate(parsed):
        url = enclosure_url(item)
        if url:
            by_url.setdefault(url, []).append(idx)

    drop: set[int] = set()
    for url, idxs in by_url.items():
        if len(idxs) < 2:
            continue
        versions = {idx: sparkle_version(parsed[idx]) for idx in idxs}
        if any(v is None for v in versions.values()):
            # Refuse to choose when a version is missing or non-numeric.
            # Leaving a duplicate is recoverable; deleting the live item is not.
            messages.append(
                f"WARN  {url}: {len(idxs)} items but a sparkle:version is "
                f"missing or non-numeric -- left untouched"
            )
            continue
        keep = max(idxs, key=lambda i: versions[i])
        for idx in idxs:
            if idx != keep:
                drop.add(idx)
                messages.append(
                    f"DROP  {url}: sparkle:version {versions[idx]} "
                    f"(superseded by {versions[keep]})"
                )

    if not drop:
        return xml_text, messages

    out: list[str] = []
    cursor = 0
    for idx, match in enumerate(items):
        if idx in drop:
            out.append(xml_text[cursor:match.start()])
            cursor = match.end()
    out.append(xml_text[cursor:])
    return "".join(out), messages


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: prune_appcast_duplicates.py <appcast.xml> [--check]",
              file=sys.stderr)
        return 2
    path = argv[1]
    check_only = "--check" in argv[2:]

    with open(path, "r", encoding="utf-8") as handle:
        original = handle.read()

    pruned, messages = prune(original)
    for message in messages:
        print(message)

    if any(message.startswith("ERROR") for message in messages):
        return 1

    if pruned == original:
        print("Appcast has one item per enclosure URL; nothing to prune.")
        return 0

    # A prune that does not still parse is a prune we do not ship.
    try:
        ET.fromstring(pruned)
    except ET.ParseError as exc:
        print(f"ERROR: pruned appcast is not well-formed XML: {exc}",
              file=sys.stderr)
        return 1

    if check_only:
        print("--check: would rewrite the appcast (not written).")
        return 1

    with open(path, "w", encoding="utf-8") as handle:
        handle.write(pruned)
    print(f"Pruned {len(messages)} stale item(s) from {path}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
