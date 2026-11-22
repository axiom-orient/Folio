#!/usr/bin/env python3
"""Create frozen synthetic real-file workloads from the canonical bilingual corpus.
Requires tokenizers==0.22.2. Uses local pinned JSON only; no model/network calls.
"""
import argparse, hashlib, json, pathlib
from tokenizers import Tokenizer, __version__
if __version__ != '0.22.2': raise SystemExit('Requires tokenizers==0.22.2')
root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
resources = root / 'Sources/FolioSemanticModels/Resources'
e = Tokenizer.from_file(str(resources / 'tokenizer.json'))
r = Tokenizer.from_file(str(resources / 'Relevance/tokenizer.json'))
canonical = root / 'Tests/FolioKnowledgeTests/Fixtures/SemanticCorpus.json'
notes = json.loads(canonical.read_bytes())['notes']
short, long = [], []
for i in range(520):
    note = notes[i % len(notes)]
    title = f"{note['title']} {i + 1:03d}"
    text = f"# {title}\n{note['text']}\n"
    short.append({'id': f'stress-{i:04d}', 'topic': note['id'].rsplit('-', 1)[0], 'text': text,
                  'tokens': len(e.encode('passage: ' + text).ids)})
    extended = text
    while len(e.encode('passage: ' + extended + note['text'] + '\n').ids) <= 512:
        extended += note['text'] + '\n'
    remaining = 512 - len(e.encode('passage: ' + extended).ids)
    extended = extended.rstrip() + ' ' + ('word ' * remaining).rstrip() + '\n'
    while len(e.encode('passage: ' + extended).ids) < 512: extended = extended.rstrip() + ' word\n'
    assert len(e.encode('passage: ' + extended).ids) == 512
    assert len(extended.encode()) < 8192
    long.append({'id': f'stress-{i:04d}', 'topic': note['id'].rsplit('-', 1)[0], 'text': extended,
                 'tokens': 512, 'pairTokensForBankQuery': len(r.encode('돈을 맡기고 이자를 받을 곳', extended).ids)})
assert len(''.join(n['text'] for n in short[:512]).encode()) < 256 * 1024
out = {'schema': 'folio.stress-corpus/1', 'generator': 'Hugging Face tokenizers ' + __version__,
       'canonicalSHA256': hashlib.sha256(canonical.read_bytes()).hexdigest(), 'short': short, 'long': long}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(out, ensure_ascii=False, separators=(',', ':')) + '\n')
print('workload SHA256', hashlib.sha256(args.output.read_bytes()).hexdigest(), 'entries', len(short))
