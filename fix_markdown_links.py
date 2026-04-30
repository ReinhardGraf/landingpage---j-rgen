#!/usr/bin/env python3
"""
fix_markdown_links.py – Bereinigt [text](url) Markdown-Korruption in Dateien.

Verwendung:
    python3 fix_markdown_links.py <datei>            # In-place fix
    python3 fix_markdown_links.py <eingabe> <ausgabe> # Mit separater Ausgabedatei

Beispiel:
    python3 fix_markdown_links.py "Multimodal RAG Image Table improved.json"
    python3 fix_markdown_links.py rag-restart.sh
"""

import sys
import json
import os

REPLACEMENTS = [
    # JavaScript property accesses
    ('[meta.page](http://meta.page)', 'meta.page'),
    ('[imageIds.map](http://imageIds.map)', 'imageIds.map'),
    ('[Date.now](http://Date.now)', 'Date.now'),
    ('[binaryData.directory](http://binaryData.directory)', 'binaryData.directory'),
    ('[chunk.page](http://chunk.page)_numbers', 'chunk.page_numbers'),
    ('[doclingDocument.pictures](http://doclingDocument.pictures)', 'doclingDocument.pictures'),
    ('[c.page](http://c.page)_numbers', 'c.page_numbers'),
    ('[row.id](http://row.id)', 'row.id'),
    ('[imgMeta.page](http://imgMeta.page)', 'imgMeta.page'),
    ('[slice.map](http://slice.map)', 'slice.map'),
    ('[cols.map](http://cols.map)', 'cols.map'),
    ('[rerankedResults.map](http://rerankedResults.map)', 'rerankedResults.map'),
    # n8n expression corruptions
    ('[json.total](http://json.total)_tables', 'json.total_tables'),
    ('[json.body.chat](http://json.body.chat)_history', 'json.body.chat_history'),
    # Bash-Script corruptions
    ('[docker-compose.dev](http://docker-compose.dev).yml', 'docker-compose.dev.yml'),
    ('[localhost](http://localhost)', 'localhost'),
    ('[iTerm.app](http://iTerm.app)', 'iTerm.app'),
    ('[Terminal.app](http://Terminal.app)', 'Terminal.app'),
    ('[rag-restart.sh](http://rag-restart.sh)', 'rag-restart.sh'),
    # Generic: weitere property accesses (Fallback-Pattern)
    ('[binaryData.directory](http://binaryData.directory)', 'binaryData.directory'),
]


def fix_content(content: str) -> tuple[str, int]:
    total = 0
    for old, new in REPLACEMENTS:
        count = content.count(old)
        if count:
            content = content.replace(old, new)
            total += count
            print(f"  ✓ {count}x  {old[:60]}")
    return content, total


def validate_json(content: str, path: str) -> bool:
    if not path.endswith('.json'):
        return True
    try:
        json.loads(content)
        return True
    except json.JSONDecodeError as e:
        print(f"  ⚠ JSON-Validierung fehlgeschlagen: {e}")
        return False


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else input_path

    if not os.path.exists(input_path):
        print(f"Fehler: Datei nicht gefunden: {input_path}")
        sys.exit(1)

    with open(input_path, 'r', encoding='utf-8') as f:
        content = f.read()

    print(f"\nVerarbeite: {input_path}")
    fixed, total = fix_content(content)

    if total == 0:
        print("  Keine Korrekturen notwendig.")
        sys.exit(0)

    validate_json(fixed, output_path)

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(fixed)

    print(f"\n{total} Korrekturen angewendet → {output_path}")


if __name__ == '__main__':
    main()
