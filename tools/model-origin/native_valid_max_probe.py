"""Focused padded-max workaround: source-exact valid-token max, FP32+FP16 controls."""
from pathlib import Path
import os,time,json,threading,traceback,resource
P=Path(__file__).resolve().parents[1]
def main():
 import psutil,numpy as np,torch,coremltools as ct
 from native_model_builder import prepare
 from scipy.optimize import linear_sum_assignment
 start=time.monotonic();stop=threading.Event();proc=psutil.Process();peak=[0];receipt=P/'results/native-valid-max.json';result={'status':'running','phase':'preparing','scope':'Same fixed800square text-only exposed context; only encoder proposal maximum excludes -infinity padded tail','deadline_seconds':300,'rss_limit_bytes':12*1024**3,'models':{}}
 def write(phase,**kw):
  result.update(kw,phase=phase,elapsed_seconds=time.monotonic()-start,process_lifetime_maxrss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss);receipt.write_text(json.dumps(result,indent=2,allow_nan=False));print(phase,flush=True)
 def guard():
  while not stop.wait(.2):
   peak[0]=max(peak[0],proc.memory_info().rss)
   if time.monotonic()-start>300 or peak[0]>12*1024**3:write(result['phase'],status='stopped_by_guard');os._exit(86)
 threading.Thread(target=guard,daemon=True).start();write('preparing')
 try:
  wrapper,image,reference,metadata=prepare(valid_token_max=True);(P/'evidence/native-valid-token-max.patch').write_text(metadata['valid_token_max_patch'])
  with torch.no_grad():patched=wrapper(image)
  result['patched_source_equal']={name:bool(torch.equal(a,b)) for name,a,b in zip(['boxes','logits'],reference,patched)}
  if not all(result['patched_source_equal'].values()):raise RuntimeError('Valid-token max changed source output')
  write('tracing')
  with torch.no_grad():traced=torch.jit.trace(wrapper,image,strict=False,check_trace=False);out=traced(image)
  result['trace_source_equal']={name:bool(torch.equal(a,b)) for name,a,b in zip(['boxes','logits'],reference,out)}
  if not all(result['trace_source_equal'].values()):raise RuntimeError('Valid-token max trace differs from source')
  traced.save(str(P/'native/countgd-fixed-bird-valid-max-800.pt'))
  for label,precision in [('fp32',ct.precision.FLOAT32),('fp16',ct.precision.FLOAT16)]:
   write('converting_'+label)
   converted=ct.convert(traced,inputs=[ct.TensorType(name='image',shape=(1,3,800,800),dtype=np.float32)],outputs=[ct.TensorType(name='boxes'),ct.TensorType(name='logits')],convert_to='mlprogram',minimum_deployment_target=ct.target.iOS17,compute_precision=precision,compute_units=ct.ComputeUnit.CPU_ONLY,skip_model_load=True)
   package=P/f'native/CountGDFixedBird800ValidMax{label.upper()}.mlpackage';converted.save(str(package));r={'package_bytes':sum(f.stat().st_size for f in package.rglob('*') if f.is_file())};result['models'][label]=r;write('predicting_'+label)
   native=ct.models.MLModel(str(package),compute_units=ct.ComputeUnit.CPU_ONLY);t=time.monotonic();raw=native.predict({'image':image.numpy()});pred={k:np.array(v,copy=True,subok=False) for k,v in raw.items()};r['prediction_seconds']=time.monotonic()-t
   # Keep source/output files distinct from earlier failed-port artifacts.
   np.savez(P/f'results/native-valid-max-{label}-output.npz',**pred)
   scores=torch.from_numpy(pred['logits']).sigmoid().max(-1).values.numpy();ref_scores=reference[1].sigmoid().max(-1).values.numpy();r['selected_above_023']=int((scores>.23).sum());r['source_selected']=int((ref_scores>.23).sum())
   a=reference[0].numpy()[0];b=pred['boxes'][0];cost=np.linalg.norm(a[:,None,:2]-b[None,:,:2],axis=-1);ii,jj=linear_sum_assignment(cost)
   r['setwise_all900']={'mean_normalized_center_distance':float(cost[ii,jj].mean()),'max_normalized_center_distance':float(cost[ii,jj].max()),'mean_source_pixel_distance':float(cost[ii,jj].mean()*400),'mean_matched_score_difference':float(abs(ref_scores[0,ii]-scores[0,jj]).mean())}
   r['indexed']={}
   for name,ref in zip(['boxes','logits'],reference):
    a=ref.numpy();b=pred[name];finite=np.isfinite(a)&np.isfinite(b);r['indexed'][name]={'max_abs_finite':float(abs(a[finite]-b[finite]).max()),'mean_abs_finite':float(abs(a[finite]-b[finite]).mean()),'finite_mask_equal':bool(np.array_equal(np.isfinite(a),np.isfinite(b)))}
   write('complete_'+label)
   del native,converted
  write('complete',status='success',sampled_peak_rss_bytes=peak[0])
 except Exception as error:traceback.print_exc();write(result['phase'],status='failed',failure_type=type(error).__name__,failure=str(error),sampled_peak_rss_bytes=peak[0])
 finally:stop.set()
if __name__=='__main__':main()
