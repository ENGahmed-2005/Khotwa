"""Real Word/PDF print QA. Requires LibreOffice, Poppler, pypdf; no mocked renderer."""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tempfile
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from pypdf import PdfReader


def identifiers(docx: Path) -> tuple[str, str]:
    with zipfile.ZipFile(docx) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise AssertionError(f"DOCX CRC failed: {docx.name} {corrupt}")
        header = ET.fromstring(archive.read("word/header1.xml"))
        text = "".join(header.itertext())
        code = re.search(r"ST-[A-F0-9]{8}", text)
        serial = re.search(r"KH-RPT-[A-F0-9-]{36}", text)
        assert code and serial, f"Missing code/serial in {docx.name} header"
        return code[0], serial[0]


def check_pdf(path: Path, code: str, serial: str) -> int:
    reader = PdfReader(path)
    assert reader.pages, f"Empty PDF {path.name}"
    for index, page in enumerate(reader.pages, 1):
        text = page.extract_text() or ""
        assert code in text and serial in text, f"Missing identifier in {path.name} page {index}"
        assert "NEVER_EXPORT" not in text, f"Free observations leaked into {path.name}"
    return len(reader.pages)


def normalized_arabic(text: str) -> str:
    # Some PDF font ToUnicode maps use visually equivalent Persian glyph aliases.
    # Normalize these aliases for extraction checks; the stored content stays untouched.
    aliases = str.maketrans({"ی": "ي", "ھ": "ه", "ک": "ك"})
    text = unicodedata.normalize("NFKC", text).translate(aliases)
    text = re.sub(r"[\u200e\u200f\u202a-\u202e\u2066-\u2069]", "", text)
    return " ".join(text.split())


def check_reference_pdf(path: Path, expected: dict[str, str]) -> None:
    text = normalized_arabic("\n".join(page.extract_text() or "" for page in PdfReader(path).pages))
    for key in ("plan", "goals"):
        assert normalized_arabic(expected[key]) in text, f"Missing visible {key} heading in {path.name}"


def check_reference_titles(directory: Path) -> list[dict[str, object]]:
    expected = json.loads((directory / "REFERENCE_EXPECTATIONS.json").read_text(encoding="utf-8"))
    assert {row["stem"] for row in expected} == {"reference-student", "reference-student-female", "reference-neutral"}, "Generate all three reference fixtures before visual QA"
    results = []
    for row in expected:
        check_reference_pdf(directory / f'{row["stem"]}.pdf', row)
        with zipfile.ZipFile(directory / f'{row["stem"]}.docx') as archive:
            root = ET.fromstring(archive.read("word/document.xml"))
            text = "".join(root.itertext())
            assert row["plan"] in text and row["goals"] in text, f'Word heading mismatch in {row["stem"]}'
            assert "يدعم التدريب مشاركة الطالب في التعلم" in text, "Recorded plan content was changed by presentation"
        results.append({"stem": row["stem"], "chrome_pdf_visible_headings": True, "word_xml_headings": True, "recorded_content_preserved": True})
    return results


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--soffice", default=shutil.which("soffice") or shutil.which("soffice.exe"))
    parser.add_argument("--pdftoppm", default=shutil.which("pdftoppm") or shutil.which("pdftoppm.exe"))
    args = parser.parse_args()
    if not args.soffice or not args.pdftoppm:
        raise SystemExit("Install LibreOffice Writer and Poppler before claiming Word visual acceptance")
    directory = args.directory.resolve()
    reference_results = check_reference_titles(directory)
    output = directory / "word-render"
    output.mkdir(parents=True, exist_ok=True)
    documents = sorted(directory.glob("*.docx"))
    assert documents, "Generate report test fixtures before running visual QA"
    results = []
    with tempfile.TemporaryDirectory(prefix="khotwa-report-lo-") as profile:
        for source in documents:
            code, serial = identifiers(source)
            subprocess.run([args.soffice, f"-env:UserInstallation={Path(profile).as_uri()}", "--headless", "--convert-to", "pdf:writer_pdf_Export", "--outdir", str(output), str(source)], check=True, timeout=90)
            converted = output / f"{source.stem}.pdf"
            assert converted.is_file(), f"No Word render created for {source.name}"
            pages = check_pdf(converted, code, serial)
            reference = next((row for row in json.loads((directory / "REFERENCE_EXPECTATIONS.json").read_text(encoding="utf-8")) if row["stem"] == source.stem), None)
            if reference is not None:
                check_reference_pdf(converted, reference)
            subprocess.run([args.pdftoppm, "-png", "-scale-to", "1500", str(converted), str(output / source.stem)], check=True, timeout=90)
            original = directory / f"{source.stem}.pdf"
            if original.is_file():
                check_pdf(original, code, serial)
            results.append({"document": source.name, "pages": pages, "all_page_identifiers": True, "png_review_required": True})
    (output / "QA.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    (output / "REFERENCE_QA.json").write_text(json.dumps(reference_results, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"word_documents_rendered": len(results), "results": results}, indent=2))


if __name__ == "__main__":
    main()
