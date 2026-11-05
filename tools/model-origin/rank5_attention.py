"""Static-size CoreML probe only: rank<=5 form of official CPU deformable attention.

Flattens level/point axes until each level's sampling grid is consumed.
Learned projections, bilinear zero padding, align_corners=False, level ordering,
attention softmax and final weighted sum match the official implementation.
"""
import torch
import torch.nn.functional as F

def rank5_forward(self,query,key=None,value=None,query_pos=None,key_padding_mask=None,reference_points=None,spatial_shapes=None,level_start_index=None,**kwargs):
 if value is None:value=query
 if query_pos is not None:query=query+query_pos
 if not self.batch_first:query=query.permute(1,0,2);value=value.permute(1,0,2)
 bs,nq,_=query.shape;nv=value.shape[1];heads=self.num_heads;points=self.num_points;levels=self.num_levels
 value=self.value_proj(value)
 if key_padding_mask is not None:value=value.masked_fill(key_padding_mask[...,None],float(0))
 value=value.view(bs,nv,heads,-1);dims=value.shape[-1]
 offsets=self.sampling_offsets(query).view(bs,nq,heads,levels*points,2)
 weights=self.attention_weights(query).view(bs,nq,heads,levels*points).softmax(-1)
 shapes=[(int(s[0]),int(s[1])) for s in spatial_shapes]
 values=value.split([h*w for h,w in shapes],dim=1);sampled=[]
 for level,(h,w) in enumerate(shapes):
  level_offsets=offsets[:,:,:,level*points:(level+1)*points,:]
  refs=reference_points[:,:,level,:]
  if reference_points.shape[-1]==2:
   # Preserve the exact float promotion and x/y division in official CPU path.
   norm=torch.tensor([w,h],dtype=spatial_shapes.dtype,device=spatial_shapes.device)
   locations=refs[:,:,None,None,:]+level_offsets/norm[None,None,None,None,:]
  elif reference_points.shape[-1]==4:
   locations=refs[:,:,None,None,:2]+level_offsets/points*refs[:,:,None,None,2:]*.5
  else:raise ValueError('Reference dimension must be2or4')
  grid=(2*locations-1).transpose(1,2).flatten(0,1)
  values_l=values[level].flatten(2).transpose(1,2).reshape(bs*heads,dims,h,w)
  sampled.append(F.grid_sample(values_l,grid,mode='bilinear',padding_mode='zeros',align_corners=False))
 attention=weights.transpose(1,2).reshape(bs*heads,1,nq,levels*points)
 output=(torch.stack(sampled,dim=-2).flatten(-2)*attention).sum(-1).view(bs,heads*dims,nq).transpose(1,2).contiguous()
 output=self.output_proj(output)
 if not self.batch_first:output=output.permute(1,0,2)
 return output
