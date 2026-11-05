"""Build the exact successful probe model in memory, without exporting or inference on import.
Copied from native_probe.py; native_model_builder-origin.txt pins that source.
"""
import json,inspect,textwrap,types,difflib
from load_probe import P,load_model
import torch,numpy as np
from PIL import Image,ImageOps
from util.misc import nested_tensor_from_tensor_list
import datasets.transforms as T

def prepare(valid_token_max=False):
 result={}
 torch.manual_seed(42);model,_=load_model('cpu',write_receipt=False)
 cache=np.load(P/'results/fixed-text-cache.npz')
 class CachedBert(torch.nn.Module):
  def __init__(self):super().__init__();self.register_buffer('hidden',torch.from_numpy(cache['hidden'].copy()))
  def forward(self,**kwargs):return {'last_hidden_state':self.hidden}
 class CachedProjection(torch.nn.Module):
  def __init__(self):super().__init__();self.register_buffer('encoded',torch.from_numpy(cache['encoded'].copy()))
  def forward(self,x):return self.encoded
 model.bert=CachedBert();model.feat_map=CachedProjection()
 class Wrapper(torch.nn.Module):
  def __init__(self,model):super().__init__();self.model=model
  def forward(self,image):
   samples=nested_tensor_from_tensor_list(image)
   output=self.model(samples,samples,[torch.empty((0,4),device=image.device)],[torch.tensor([0],device=image.device)],captions=['bird .'])
   return output['pred_boxes'],output['pred_logits']
 wrapper=Wrapper(model).eval();corpus=json.loads((P.parent/'varied-evaluation/corpus/manifest.json').read_text());entry=next(x for x in corpus['images'] if x['id']=='starling-murmuration')
 im=ImageOps.exif_transpose(Image.open(P.parents[3]/entry['path'])).convert('RGB').crop((1000,595,1400,995))
 transform=T.Compose([T.RandomResize([800],max_size=1333),T.ToTensor(),T.Normalize([.485,.456,.406],[.229,.224,.225])]);image,_=transform(im,None);image=image[None]
 with torch.no_grad():reference=wrapper(image)
 # Equivalent scalar Boolean control flow avoids PyTorch2.5 trace's Tensor,bool eq bug.
 # Keep author files untouched; exact output comparison below is mandatory.
 import inspect,textwrap,types,difflib
 original=textwrap.dedent(inspect.getsource(model.forward))
 patched=original.replace('if text_dict["text_token_mask"][b][j] == True:','if bool(text_dict["text_token_mask"][b][j]):')
 assert patched!=original
 namespace=dict(inspect.getmodule(model).__dict__)
 # This prompt's special-token masks and position IDs are also image independent.
 # Capture exact official helper outputs once, eliminating unsupported in-place OR.
 mask_helper=namespace['generate_masks_with_special_tokens_and_transfer_map']
 fixed_tokens=model.tokenizer(['bird .'],padding='longest',return_tensors='pt')
 fixed_masks=mask_helper(fixed_tokens,model.specical_tokens,model.tokenizer)
 namespace['generate_masks_with_special_tokens_and_transfer_map']=lambda *a,**kw:fixed_masks
 exec(compile(patched,'<countgd-native-boolean-forward>','exec'),namespace)
 model.forward=types.MethodType(namespace['forward'],model)
 # CoreML frontend loses a singleton rank while splitting constant text positions.
 # Cache this further image-independent official computation as well.
 encoder=model.transformer.encoder
 encoder_namespace=dict(inspect.getmodule(encoder).__dict__)
 fixed_sine=encoder_namespace['get_sine_pos_embed'](fixed_masks[1][...,None],num_pos_feats=256,exchange_xy=False)
 encoder_namespace['get_sine_pos_embed']=lambda *a,**kw:fixed_sine
 exec(compile(textwrap.dedent(inspect.getsource(encoder.forward)),'<countgd-native-fixed-text-position>','exec'),encoder_namespace)
 encoder.forward=types.MethodType(encoder_namespace['forward'],encoder)
 padding_patches=0
 for module in model.modules():
  if type(module).__name__=='ContrastiveEmbed':
   pad_original=textwrap.dedent(inspect.getsource(module.forward))
   pad_patched=pad_original.replace('new_res[..., : res.shape[-1]] = res','new_res = torch.cat((res, torch.full((*res.shape[:-1], self.max_text_len - res.shape[-1]), float("-inf"), device=res.device)), dim=-1) #')
   assert pad_patched!=pad_original
   pad_namespace=dict(inspect.getmodule(module).__dict__);exec(compile(pad_patched,'<countgd-native-padding>','exec'),pad_namespace)
   module.forward=types.MethodType(pad_namespace['forward'],module);padding_patches+=1
 result['trace_only_patch']='evidence/native-boolean-trace.patch; scalar Boolean truth test replaces == True; author files unchanged'
 result['fixed_mask_cache']='Exact official special-token masks and positions precomputed for fixed bird . input; removes unsupported image-independent __ior__'
 result['fixed_text_position_cache']={'shape':list(fixed_sine.shape),'reason':'Exact official fixed-text sine-position embedding precomputed; avoids frontend rank error in constant slice'}
 result['padding_rewrite']={'modules':padding_patches,'patch':'evidence/native-padding-trace.patch','reason':'Equivalent concatenate negative-infinity padding replaces slice assignment rejected by frontend shape inference'}
 from rank5_attention import rank5_forward
 rank5_modules=0
 for module in model.modules():
  if type(module).__name__=='MultiScaleDeformableAttention':
   module.forward=types.MethodType(rank5_forward,module);rank5_modules+=1
 result['rank5_deformable_attention']={'modules':rank5_modules,'source':'scripts/rank5_attention.py','reason':'Keep levels/points flattened until per-level grid sampling; CoreML disallows original rank6 tensor'}
 if valid_token_max:
  transformer=model.transformer
  source=textwrap.dedent(inspect.getsource(transformer.forward))
  patched=source.replace('topk_logits = enc_outputs_class_unselected.max(-1)[0]','topk_logits = enc_outputs_class_unselected[..., :text_dict["encoded_text"].shape[1]].max(-1)[0]')
  assert source!=patched
  transform_namespace=dict(inspect.getmodule(transformer).__dict__);exec(compile(patched,'<countgd-native-valid-token-max>','exec'),transform_namespace)
  transformer.forward=types.MethodType(transform_namespace['forward'],transformer)
  result['valid_token_max_patch']=''.join(difflib.unified_diff(source.splitlines(True),patched.splitlines(True),fromfile='author-transformer',tofile='native-valid-token-max'))
 return wrapper,image,reference,result
