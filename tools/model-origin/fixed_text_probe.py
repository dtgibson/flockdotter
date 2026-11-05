"""Bounded architecture-only equivalence probe; not another quality evaluation.

Checks fixed prompt, batch one, eval FP32 CPU on one already-exposed context.
Does not modify author source, model weights, frozen evaluation or load receipt.
"""
import os,sys,json,time,threading,hashlib,resource
from load_probe import P,load_model
import torch,numpy as np,psutil
from PIL import Image,ImageOps
from util.misc import nested_tensor_from_tensor_list
import datasets.transforms as T
stop=threading.Event(); proc=psutil.Process(); rss=[]
def watch():
 start=time.monotonic()
 while not stop.wait(.05):
  rss.append(proc.memory_info().rss)
  if rss[-1]>12*1024**3 or time.monotonic()-start>90:os._exit(86)
th=threading.Thread(target=watch,daemon=True);th.start()
try:
 torch.manual_seed(42)
 model,_=load_model('cpu',write_receipt=False)
 all_count=sum(p.numel() for p in model.parameters())
 bert_count=sum(p.numel() for p in model.bert.parameters())
 projection_count=sum(p.numel() for p in model.feat_map.parameters())
 corpus=json.loads((P.parent/'varied-evaluation/corpus/manifest.json').read_text())
 ent=next(e for e in corpus['images'] if e['id']=='starling-murmuration')
 source=ImageOps.exif_transpose(Image.open(P.parents[3]/ent['path'])).convert('RGB')
 context=source.crop((1000,595,1400,995))
 transform=T.Compose([T.RandomResize([800],max_size=1333),T.ToTensor(),T.Normalize([.485,.456,.406],[.229,.224,.225])])
 tensor,_=transform(context,None); samples=nested_tensor_from_tensor_list(tensor[None]); empty=[torch.empty((0,4))]; labels=[torch.tensor([0])]
 captured={}
 def bert_hook(m,a,kw,out):
  captured['inputs']={k:v.detach().clone() for k,v in kw.items()}
  captured['hidden']=out['last_hidden_state'].detach().clone()
 def projection_hook(m,a,out):captured['encoded']=out.detach().clone()
 h1=model.bert.register_forward_hook(bert_hook,with_kwargs=True);h2=model.feat_map.register_forward_hook(projection_hook)
 def run():
  with torch.no_grad():return model(samples,samples,empty,labels,captions=['bird .'])
 before=time.perf_counter(); reference=run(); first_seconds=time.perf_counter()-before
 h1.remove();h2.remove()
 class CachedBert(torch.nn.Module):
  def __init__(self):
   super().__init__();self.register_buffer('hidden',captured['hidden'])
  def forward(self,**kwargs):
   if kwargs.keys()!=captured['inputs'].keys() or any(not torch.equal(v,captured['inputs'][k]) for k,v in kwargs.items()):raise RuntimeError('Cache supports exact fixed token inputs only')
   return {'last_hidden_state':self.hidden}
 class CachedProjection(torch.nn.Module):
  def __init__(self):super().__init__();self.register_buffer('encoded',captured['encoded'])
  def forward(self,x):return self.encoded
 model.bert=CachedBert();model.feat_map=CachedProjection()
 residual=sum(p.numel() for p in model.parameters())
 before=time.perf_counter();cached=run();cached_seconds=time.perf_counter()-before
 comparisons={}
 for k in ['pred_boxes','pred_logits']:
  finite=torch.isfinite(reference[k])&torch.isfinite(cached[k])
  comparisons[k]={'shape':list(reference[k].shape),'bitwise_equal':bool(torch.equal(reference[k],cached[k])),'max_abs_difference_finite_values':float((reference[k][finite]-cached[k][finite]).abs().max()),'nonfinite_values':int((~finite).sum()),'note':'Padded token logits contain matching negative infinities by design.' if not bool(finite.all()) else None}
 score=lambda out:out['pred_logits'][0].sigmoid().max(-1).values>.23
 receipt={'purpose':'Architecture-only post-evaluation fixed-text simplification proof, one already-exposed context; not a new quality result or shipping model','prompt':'bird .','batch':1,'device':'cpu','dtype':'float32','image':'starling-murmuration','source_context_xywh':[1000,595,400,400],'input_shape':list(tensor.shape),'original_parameters':all_count,'bert_parameters':bert_count,'feat_map_parameters':projection_count,'residual_parameters':residual,'residual_parameter_bytes':{'fp32':residual*4,'fp16':residual*2,'int8_ideal_payload':residual,'int4_ideal_payload':(residual+1)//2},'cached_hidden_shape':list(captured['hidden'].shape),'cached_projected_shape':list(captured['encoded'].shape),'projected_fp32_bytes':captured['encoded'].numel()*4,'comparisons':comparisons,'selection_mask_bitwise_equal':bool(torch.equal(score(reference),score(cached))),'selected':int(score(cached).sum()),'reference_seconds':first_seconds,'cached_seconds':cached_seconds,'maxrss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'limits':['One shape/context, exact same token inputs only; no CoreML, quantization, native app, minimum-OS or Intel proof.','Cache includes model-weight-dependent projected text; dynamic image/text fusion is retained.','INT8/INT4 entries are arithmetic weight payload estimates without scales, metadata, alignment, uncompressed layers or runtime buffers; not exported package sizes.','One consecutive timing per mode is not a controlled performance benchmark.']}
 (P/'results/fixed-text-probe.json').write_text(json.dumps(receipt,indent=2))
 np.savez_compressed(P/'results/fixed-text-cache.npz',hidden=captured['hidden'].numpy(),encoded=captured['encoded'].numpy(),**{k:v.numpy() for k,v in captured['inputs'].items()})
 print(json.dumps(receipt,indent=2),flush=True)
finally:stop.set();th.join()
