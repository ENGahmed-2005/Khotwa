"""Real Word/PDF print QA. Requires LibreOffice, Poppler, pypdf; no mocked renderer."""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tempfile
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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--soffice", default=shutil.which("soffice") or shutil.which("soffice.exe"))
    parser.add_argument("--pdftoppm", default=shutil.which("pdftoppm") or shutil.which("pdftoppm.exe"))
    args = parser.parse_args()
    if not args.soffice or not args.pdftoppm:
        raise SystemExit("Install LibreOffice Writer and Poppler before claiming Word visual acceptance")
    directory = args.directory.resolve()
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
            subprocess.run([args.pdftoppm, "-png", "-scale-to", "1500", str(converted), str(output / source.stem)], check=True, timeout=90)
            original = directory / f"{source.stem}.pdf"
            if original.is_file():
                check_pdf(original, code, serial)
            results.append({"document": source.name, "pages": pages, "all_page_identifiers": True, "png_review_required": True})
    (output / "QA.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"word_documents_rendered": len(results), "results": results}, indent=2))


if __name__ == "__main__":
    main()
