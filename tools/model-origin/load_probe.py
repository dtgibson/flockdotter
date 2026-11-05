"""CountGD exact author safetensors coverage/CPU portability probe; no predictions yet."""
import os,pathlib,sys,time,json,hashlib,platform,resource
P=pathlib.Path(__file__).resolve().parents[1]
os.environ['HF_HUB_OFFLINE']='1';os.environ['TRANSFORMERS_OFFLINE']='1';os.environ['HF_HOME']=str(P/'hf-cache');os.environ['MPLCONFIGDIR']=str(P/'mpl-config')
SRC=P/'CountGD-Space-6e82e59569a84ee5c6aafa35d396f2d2bee57be2';sys.path.insert(0,str(SRC))
import torch
torch.set_num_threads(4)
from safetensors.torch import load_file
from util.slconfig import SLConfig
from types import SimpleNamespace

def build(device='cpu'):
 cfg=SLConfig.fromfile(str(SRC/'cfg_app.py'));args=SimpleNamespace(**cfg._cfg_dict.to_dict());args.device=device;args.text_encoder_type=str(P/'models/bert-base-uncased');args.use_checkpoint=False;args.use_transformer_ckpt=False
 from models.registry import MODULE_BUILD_FUNCS
 import models
 model,criterion,postprocessors=MODULE_BUILD_FUNCS.get(args.modelname)(args)
 return model.eval(),args

def load_model(device='cpu',write_receipt=True):
 start=time.perf_counter();model,args=build(device);state=load_file(str(P/'models/countgd-model.safetensors'))
 expected=model.state_dict();missing=sorted(set(expected)-set(state));unexpected=sorted(set(state)-set(expected));mismatched=[{'key':k,'expected':list(expected[k].shape),'received':list(state[k].shape)} for k in set(expected)&set(state) if expected[k].shape!=state[k].shape]
 # HF safetensors removes aliases from tied tensors. Reconstruct ONLY exact same-storage/shape aliases.
 aliases={};unresolved=[]
 for k in missing:
  matches=[other for other in state if other in expected and expected[other].data_ptr()==expected[k].data_ptr() and expected[other].shape==expected[k].shape and expected[other].stride()==expected[k].stride()]
  if matches:
   other=sorted(matches)[0];state[k]=state[other];aliases[k]=other
  else:unresolved.append(k)
 if unresolved or unexpected or mismatched:
  result={'status':'incompatible','missing':missing,'unresolved_missing':unresolved,'unexpected':unexpected,'shape_mismatches':mismatched,'alias_reconstruction':aliases};(P/'results/load-probe.json').write_text(json.dumps(result,indent=2));raise RuntimeError(result)
 receipt=model.load_state_dict(state,strict=True);parameters=sum(x.numel() for x in model.parameters());del state
 model=model.to(device)
 result={'status':'strict_load_passed_after_documented_tied_alias_reconstruction','device':device,'model_source_space_revision':SRC.name.removeprefix('CountGD-Space-'),'weight_revision':'6b989ad11db9413e44863ea5c57735cae6cacff8','weight_file_sha256':hashlib.sha256((P/'models/countgd-model.safetensors').read_bytes()).hexdigest(),'missing_before_alias_reconstruction':missing,'alias_reconstruction':aliases,'missing_after_strict_load':receipt.missing_keys,'unexpected_after_strict_load':receipt.unexpected_keys,'parameters':parameters,'parameter_float32_bytes':parameters*4,'load_seconds':time.perf_counter()-start,'process_maxrss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'torch':torch.__version__,'mps_available':torch.backends.mps.is_available(),'host':platform.platform(),'notes':['Uses official built-in nonCUDA PyTorch deformable-attention fallback.','Disables training gradient-checkpoint options during no-grad eval; no architecture or weights changed.','No claim of bitwise equality to separate GoogleDrive/Space pth file; exact author HFartifact evaluated.']}
 if write_receipt:(P/'results/load-probe.json').write_text(json.dumps(result,indent=2))
 print(json.dumps(result,indent=2),flush=True);return model,args
if __name__=='__main__':load_model()
