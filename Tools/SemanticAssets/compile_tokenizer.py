#!/usr/bin/env python3
"""Compile the two pinned XLM-R JSONs into a shared, read-only scalar trie.
No trained parameters, IDs, Float32 scores, or normalizer bytes are changed.
Standard library only. --check verifies regeneration without writing resources.
"""
import argparse, base64, hashlib, json, pathlib, struct

if not __debug__: raise SystemExit('Run without -O: source-contract assertions must remain enabled.')

ROOT = pathlib.Path(__file__).resolve().parents[2]
RESOURCES = ROOT / 'Sources/FolioSemanticModels/Resources'
INPUTS = {'tokenizer.json': 'cd98e5698b201ba914efb8c18b6709fa8735ab71dcad8d2b431e52e8bf68d932',
          'Relevance/tokenizer.json': '62c24cdc13d4c9952d63718d6c9fa4c287974249e16b7ade6d5a85e7bbb75626'}

def compile_assets():
    paths = [RESOURCES / p for p in INPUTS]
    source = [json.loads(p.read_bytes()) for p in paths]
    # Always validate each source against its existing model manifest.
    for path in paths:
        manifest = json.loads((path.parent / 'MODEL_SOURCE.json').read_bytes())
        assert hashlib.sha256(path.read_bytes()).hexdigest() == manifest['files'][path.name] == INPUTS[str(path.relative_to(RESOURCES))]
    a, b = source
    assert a['model']['vocab'] == b['model']['vocab'] and a['model']['unk_id'] == b['model']['unk_id'] == 3
    assert a['model'].get('byte_fallback', False) is False and b['model'].get('byte_fallback', False) is False
    normalizer = a['normalizer']['normalizers']
    assert a['normalizer']['type'] == 'Sequence' and normalizer[0]['type'] == 'Precompiled'
    assert normalizer[1:] == [{'type': 'Replace', 'pattern': {'Regex': ' {2,}'}, 'content': ' '}]
    assert b['normalizer']['type'] == 'Precompiled'
    assert normalizer[0]['precompiled_charsmap'] == b['normalizer']['precompiled_charsmap']
    assert a['pre_tokenizer'] == {'type': 'Metaspace', 'replacement': '▁', 'prepend_scheme': 'always', 'split': True}
    assert b['pre_tokenizer'] == {'type': 'Sequence', 'pretokenizers': [{'type': 'WhitespaceSplit'}, {'type': 'Metaspace', 'replacement': '▁', 'add_prefix_space': True}]}
    assert a['post_processor'] == b['post_processor']
    for model in source:
        assert model['truncation'] is None and model['padding'] is None
        assert [(t['id'], t['content'], t['lstrip'], t['rstrip'], t['single_word'], t['special']) for t in model['added_tokens']] == [
            (0, '<s>', False, False, False, True), (1, '<pad>', False, False, False, True),
            (2, '</s>', False, False, False, True), (3, '<unk>', False, False, False, True),
            (250001, '<mask>', model is b, False, False, True)]
    children = [{}]; leaves = [None]
    for token_id, (token, score) in enumerate(a['model']['vocab']):
        node = 0
        for scalar in map(ord, token):
            if scalar not in children[node]:
                children[node][scalar] = len(children); children.append({}); leaves.append(None)
            node = children[node][scalar]
        assert leaves[node] is None, 'Duplicate scalar vocabulary'
        leaves[node] = (token_id, score)
    nodes = bytearray(); edges = bytearray()
    for child_map, leaf in zip(children, leaves):
        token_id, score = leaf if leaf is not None else (0xffffffff, 0.0)
        nodes += struct.pack('<IIIf', len(edges) // 8, len(child_map), token_id, score)
        for scalar, child in sorted(child_map.items()): edges += struct.pack('<II', scalar, child)
    vocabulary = a['model']['vocab']
    # Match the upstream Float32 minScore - 10 computation.
    f32 = lambda x: struct.unpack('<f', struct.pack('<f', x))[0]
    minimum = min(f32(score) for _, score in vocabulary)
    header = b'FOLIOTK1' + struct.pack('<IIIIf', len(children), len(edges)//8, len(vocabulary), 3, f32(minimum - 10)) + b'\0'*4
    files = {'Unigram.foliotokens': header + nodes + edges,
             'Precompiled.charsmap': base64.b64decode(normalizer[0]['precompiled_charsmap'])}
    manifest = {'format': 'folio.scalar-unigram/1', 'compiler': 'Tools/SemanticAssets/compile_tokenizer.py',
                'algorithmSource': 'huggingface/swift-transformers@1.4.0',
                'inputs': {str(p.relative_to(RESOURCES)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
                'nodes': len(children), 'vocabulary': len(vocabulary),
                'files': {p: hashlib.sha256(data).hexdigest() for p, data in files.items()}}
    files['TOKENIZER_SOURCE.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
    return files

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
    for name, data in compile_assets().items():
        destination = RESOURCES / name
        if args.check:
            if destination.read_bytes() != data: raise SystemExit(f'Regeneration mismatch: {name}')
        else: destination.write_bytes(data)
        print(f'{name}: {len(data)} bytes, sha256={hashlib.sha256(data).hexdigest()}')
