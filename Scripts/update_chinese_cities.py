#!/usr/bin/env python3
"""Build the optional Chinese city catalog from official GeoNames downloads (CC BY 4.0)."""
import argparse
import datetime
import hashlib
import io
import json
import re
import unicodedata
import zipfile
from pathlib import Path


def key(value):
    folded = unicodedata.normalize("NFKD", value.casefold())
    return " ".join("".join(c for c in folded if not unicodedata.combining(c)).split())


def chinese(value):
    return bool(re.search(r"[\u3400-\u9fff]", value)) and not re.search(r"[A-Za-z]", value)


def lines(path, member):
    with zipfile.ZipFile(path) as archive:
        with archive.open(member) as source:
            yield from io.TextIOWrapper(source, encoding="utf-8")


def build(source_dir, output, version):
    records = {}
    for line in lines(source_dir / "cities500.zip", "cities500.txt"):
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 19 or fields[6] != "P":
            raise ValueError("Unexpected GeoNames city record")
        records[fields[0]] = fields

    names = {}
    current_aliases = {}
    preferred_english = {}
    priority = {"zh-CN": 4, "zh-Hans": 4, "zh": 3, "zh-TW": 2, "zh-Hant": 2, "zh-HK": 1}
    for line in lines(source_dir / "alternateNamesV2.zip", "alternateNamesV2.txt"):
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 8 or fields[1] not in records:
            continue
        if fields[6] == "1" or fields[7] == "1":
            continue
        alias = key(fields[3])
        if fields[2] not in {"link", "post", "iata", "icao", "faac", "wkdt", "abbr"} and alias:
            if alias.isascii() or any("CYRILLIC" in unicodedata.name(c, "") for c in fields[3]):
                current_aliases.setdefault(fields[1], set()).add(alias)
        if fields[2] == "en" and fields[4] == "1":
            preferred_english.setdefault(fields[1], set()).add(alias)
        if fields[2] not in priority or not chinese(fields[3]):
            continue
        score = (priority[fields[2]], fields[4] == "1", fields[5] != "1")
        if fields[1] not in names or score > names[fields[1]][0]:
            names[fields[1]] = (score, fields[3])

    cities = []
    # GeoNames currently has no Chinese alternate for this otherwise verified name.
    overrides = {"463829": {"name": "泽列诺格勒", "source": "https://www.vtbreg.ru/cn/company/feedback/"}}
    for identifier, fields in records.items():
        name = overrides.get(identifier, {}).get("name") or names.get(identifier, (None, None))[1]
        if name is None and fields[8] in {"CN", "TW", "HK", "MO"} and chinese(fields[1]):
            name = fields[1]
        if name is None:
            continue
        primary = {key(fields[1]), key(fields[2])} | preferred_english.get(identifier, set())
        # The convenience city table includes historical aliases; use explicitly current alternates.
        aliases = sorted(primary | current_aliases.get(identifier, set()))
        cities.append(dict(geonameID=int(identifier), countryCode=fields[8], admin1=fields[10],
                           aliases=aliases, primaryNames=sorted(primary), nameChinese=name,
                           latitude=float(fields[4]), longitude=float(fields[5])))
    cities.sort(key=lambda city: city["geonameID"])
    used_regions = {f'{city["countryCode"]}.{city["admin1"]}' for city in cities}
    regions = {}
    for line in (source_dir / "admin1CodesASCII.txt").read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if fields[0] in used_regions:
            regions[fields[0]] = sorted({key(fields[1]), key(fields[2]), key(fields[0].split(".", 1)[1])})

    result = dict(version=version, source="https://www.geonames.org/", license="CC BY 4.0",
                  scope="cities500 populated places with available Chinese alternate names",
                  curatedOverrides=overrides,
                  inputSHA256={name: hashlib.file_digest((source_dir / name).open("rb"), "sha256").hexdigest()
                               for name in ["cities500.zip", "alternateNamesV2.zip", "admin1CodesASCII.txt"]},
                  regions=regions, cities=cities)
    assert len(cities) > 1000
    assert any("zelenograd" in city["aliases"] and city["countryCode"] == "RU" for city in cities)
    output.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Built {len(cities)} Chinese city records, {sum(len(c['aliases']) for c in cities)} aliases, {output.stat().st_size:,} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True,
                        help="Directory containing cities500.zip, alternateNamesV2.zip and admin1CodesASCII.txt")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "HopWorld/Resources/ChineseCities.json")
    parser.add_argument("--version", default=datetime.datetime.now(datetime.timezone.utc).date().isoformat())
    args = parser.parse_args()
    build(args.source_dir, args.output, args.version)
