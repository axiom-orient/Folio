#!/usr/bin/env python3
"""Independent reference generator; requires tokenizers==0.22.2. Seed and cases are fixed."""
import json, pathlib, random, hashlib, tokenizers
if tokenizers.__version__ != '0.22.2': raise SystemExit('Install tokenizers==0.22.2 for the pinned reference.')
r=pathlib.Path(__file__).resolve().parents[2]; d=r/'Sources/FolioSemanticModels/Resources'; e=tokenizers.Tokenizer.from_file(str(d/'tokenizer.json')); p=tokenizers.Tokenizer.from_file(str(d/'Relevance/tokenizer.json'))
randomizer=random.Random(623128); vocab=json.loads((d/'tokenizer.json').read_bytes())['model']['vocab']
parts=['은행','이자','배관','수도꼭지','물방울','임베딩','승인','복구','원문','검색','가나다','가나다','café','cafe\u0301','▁\u0301','ｆｕｌｌｗｉｄｔｈ','①','\uff5e','𠮷','\u200d','\u200b','\u00a0','\t','\n','\r\n','  ','<s>','</s>','<pad>','<unk>','<mask>','< mask >','😅','👩🏽\u200d💻','\x00','\u0085','\u2028','\u2060','\ufffd']
texts=['', ' ', '   ', '▁', '▁▁a', '가나다', 'a\x00b', 'query: <s> <mask> 😅']
for i in range(504):
 pool=parts+[vocab[randomizer.randrange(len(vocab))][0] for _ in range(6)]
 texts.append(''.join(randomizer.choice(pool) for _ in range(randomizer.randrange(1,18))))
out={'generator':'Hugging Face tokenizers '+tokenizers.__version__, 'seed':623128, 'tokenizerSHA256':{str(x.relative_to(d)):hashlib.sha256(x.read_bytes()).hexdigest() for x in [d/'tokenizer.json',d/'Relevance/tokenizer.json']},'embedding':[{'text':t,'ids':e.encode(t).ids} for t in texts], 'relevance':[{'query':texts[i], 'passage':texts[511-i], 'ids':p.encode(texts[i],texts[511-i]).ids} for i in range(256)]}
(r/'Tests/FolioKnowledgeTests/Fixtures/CompactTokenizerConformance.json').write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
