#!/usr/bin/env python3
"""Adds a release to the Sparkle appcast (appcast.xml at the repository root), newest first.

Usage: scripts/appcast.py --version 0.2.0 --build 7 --url https://…/Panes-0.2.0.dmg \
           --signature "sparkle:edSignature=\"…\" length=\"…\"" [--channel beta] [--notes-url …]

--signature takes sign_update's output as is. Re-adding a build replaces its item.
"""
import argparse
import email.utils
import pathlib
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def sparkle(tag):
    return f"{{{SPARKLE}}}{tag}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", default=str(pathlib.Path(__file__).resolve().parent.parent / "appcast.xml"))
    parser.add_argument("--title", default="Panes")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion")
    parser.add_argument("--url", required=True, help="download URL of the DMG")
    parser.add_argument("--signature", required=True, help="output of sign_update")
    parser.add_argument("--channel", help="e.g. beta; stable releases have none")
    parser.add_argument("--notes-url")
    parser.add_argument("--minimum-system", default="13.0")
    args = parser.parse_args()

    fields = dict(re.findall(r'([\w:]+)="([^"]*)"', args.signature))
    if "sparkle:edSignature" not in fields or "length" not in fields:
        parser.error("--signature must contain sparkle:edSignature=\"…\" and length=\"…\"")

    path = pathlib.Path(args.appcast)
    if path.exists():
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = args.title
        tree = ET.ElementTree(root)

    for item in channel.findall("item"):
        if item.findtext(sparkle("version")) == args.build:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(localtime=True)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system
    if args.channel:
        ET.SubElement(item, sparkle("channel")).text = args.channel
    if args.notes_url:
        ET.SubElement(item, sparkle("releaseNotesLink")).text = args.notes_url
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        sparkle("edSignature"): fields["sparkle:edSignature"],
        "length": fields["length"],
        "type": "application/octet-stream",
    })

    # Newest first: after the channel's own elements, before the other items.
    first_item = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first_item, item)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    print(f"Added {args.version} ({args.build}) to {path}")


if __name__ == "__main__":
    main()
