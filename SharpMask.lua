--[[----------------------------------------------------------------------------
Copyright (c) 2016-present, Facebook, Inc. All rights reserved.
This source code is licensed under the BSD-style license found in the
LICENSE file in the root directory of this source tree. An additional grant
of patent rights can be found in the PATENTS file in the same directory.

When initialized, it loads a pre-trained DeepMask and create the refinement
modules.
SharpMask class members:
  - self.trunk: common trunk (from trained DeepMask model)
  - self.scoreBranch: score head architecture (from trained DeepMask model)
  - self.maskBranchDM: mask head architecture (from trained DeepMask model)
  - self.refs: ensemble of refinement modules for top-down path
------------------------------------------------------------------------------]]

require 'nn'
require 'nnx'
require 'cunn'
require 'cudnn'
local utils = paths.dofile('modelUtils.lua')

local SharpMask, _ = torch.class('nn.SharpMask','nn.Container')

--------------------------------------------------------------------------------
-- function: init
function SharpMask:__init(config)
  self.km, self.ks = config.km, config.ks
  assert(self.km >= 16 and self.km%16==0 and self.ks >= 16 and self.ks%16==0)

  self.skpos = {8,6,5,3} -- positions to forward horizontal nets
  self.inps = {}
  self.inps2 = {}

  -- create bottom-up flow (from deepmask)
  local m = torch.load(config.dm..'/model.t7')
  local deepmask = m.model
  self.trunk = deepmask.trunk
  self.scoreBranch = deepmask.scoreBranch
  self.maskBranchDM = deepmask.maskBranch
  self.fSz = deepmask.fSz

  -- create refinement modules
  self:createTopDownRefinement(config)

  -- number of parameters
  local nh,nv = 0,0
  for k,v in pairs(self.neths) do
    for kk,vv in pairs(v:parameters()) do nh = nh+vv:nElement() end
  end
  for k,v in pairs(self.netvs) do
    for kk,vv in pairs(v:parameters()) do nv = nv+vv:nElement() end
  end
  print(string.format('| number of paramaters net h: %d', nh))
  print(string.format('| number of paramaters net v: %d', nv))
  print(string.format('| number of paramaters total: %d', nh+nv))
  self:cuda()
end

--------------------------------------------------------------------------------
-- function: create vertical nets
function SharpMask:createVertical(config)
  local netvs = {}

  local n0 = nn.Sequential()
  n0:add(nn.Linear(512,self.fSz*self.fSz*self.km))
  n0:add(nn.View(config.batch,self.km,self.fSz,self.fSz))
  netvs[0]=n0:cuda()

  for i = 1, #self.skpos do
    local netv = nn.Sequential()
    local nInps = self.km/2^(i-1)

    netv:add(nn.SpatialSymmetricPadding(1,1,1,1))
    netv:add(cudnn.SpatialConvolution(nInps,nInps,3,3,1,1))
    netv:add(cudnn.ReLU())

    netv:add(nn.SpatialSymmetricPadding(1,1,1,1))
    netv:add(cudnn.SpatialConvolution(nInps,nInps/2,3,3,1,1))

    table.insert(netvs,netv:cuda())
  end

  self.netvs = netvs
  return netvs
end

--------------------------------------------------------------------------------
-- function: create horizontal nets
function SharpMask:createHorizontal(config)
  local neths = {}
  local nhu1,nhu2,crop
  for i =1,#self.skpos do
    local h = nn.Sequential()
    local nInps = self.ks/2^(i-1)

    if i == 1 then nhu1,nhu2,crop=1024,64,0
    elseif i == 2 then nhu1,nhu2,crop = 512,64,-2
    elseif i == 3 then nhu1,nhu2,crop = 256,64,-4
    elseif i == 4 then nhu1,nhu2,crop = 64,32,-8
    end
    if crop ~= 0 then h:add(nn.SpatialZeroPadding(crop,crop,crop,crop)) end

    h:add(nn.SpatialSymmetricPadding(1,1,1,1))
    h:add(cudnn.SpatialConvolution(nhu1,nhu2,3,3,1,1))
    h:add(cudnn.ReLU())

    h:add(nn.SpatialSymmetricPadding(1,1,1,1))
    h:add(cudnn.SpatialConvolution(nhu2,nInps,3,3,1,1))
    h:add(cudnn.ReLU())

    h:add(nn.SpatialSymmetricPadding(1,1,1,1))
    h:add(cudnn.SpatialConvolution(nInps,nInps/2,3,3,1,1))

    table.insert(neths,h:cuda())
  end

  self.neths = neths
  return neths
end

--------------------------------------------------------------------------------
-- function: create horizontal 2 nets
function SharpMask:createHorizontal2(config)
  local neth2s = {}

  for i = 1, #self.skpos do
    local nInps = self.km/2^(i-1)

    output = 1024/2^(i-1)
    if i==4 then output = 64 end
    local neth2 = nn.Sequential()
    
    neth2:add(nn.SpatialSymmetricPadding(1,1,1,1))
    neth2:add(cudnn.SpatialConvolution(nInps,64,3,3,1,1))
    neth2:add(cudnn.ReLU())

    neth2:add(nn.SpatialSymmetricPadding(1,1,1,1))
    neth2:add(cudnn.SpatialConvolution(64,output,3,3,1,1))

    table.insert(neth2s,neth2:cuda())
  end

  self.neth2s = neth2s
  return neth2s

end
--------------------------------------------------------------------------------
-- function: create refinement modules
function SharpMask:refinement(neth,netv)
   local ref = nn.Sequential()
   local par = nn.ParallelTable():add(neth):add(netv)
   ref:add(par)
   ref:add(nn.CAddTable(2))
   ref:add(cudnn.ReLU())
   ref:add(nn.SpatialUpSamplingNearest(2))

   return ref:cuda()
end

function SharpMask:createTopDownRefinement(config)
  -- create horizontal nets
  self:createHorizontal(config)

  -- create vertical nets
  self:createVertical(config)

  local refs = {}
  refs[0] = self.netvs[0]
  for i = 1, #self.skpos do
    table.insert(refs,self:refinement(self.neths[i],self.netvs[i]))
  end

  local finalref = refs[#refs]
  finalref:add(nn.SpatialSymmetricPadding(1,1,1,1))
  finalref:add(cudnn.SpatialConvolution((self.km)/2^(#refs),1,3,3,1,1))
  finalref:add(nn.View(config.batch,config.gSz*config.gSz))

  self.refs = refs

  self:createHorizontal2(config)

  self.trunk2 = self.trunk:clone();
  self.refs2 = self.refs:clone();

  return refs
end

function SharpMask:forwardMod1(input)

  local currentOutput = self.trunk:forward(input)

  -- forward refinement modules
  currentOutput = self.refs[0]:forward(currentOutput)
  for k = 1,#self.refs do
    local F = self.trunk.modules[self.skpos[k]].output
    self.inps[k] = {F,currentOutput}
    currentOutput = self.refs[k]:forward(self.inps[k])
  end
  self.output = currentOutput
  return self.output
end


--------------------------------------------------------------------------------
-- function: forward
function SharpMask:forward(input)
  -- forward bottom-up 1 pass
  forwardMod1(input)

  ---- trunk module forward second pass ---- 
  currentOutput = input
  for k = 1, #3 do
    currentOutput = self.trunk2.modules[k]:forward(currentOutput)
  end

  local netv2Inp ={}

  F = self.neth2s[4]:forward(self.refs[4].output)
  torch.add(currentOutput, currentOutput, F)
  table.insert(netv2Inp, currentOutput)
  currentOutput = self.trunk2.modules[4]:forward(currentOutput)
  currentOutput = self.trunk2.modules[5]:forward(currentOutput)

  F = self.neth2s[3]:forward(self.refs[3].output)
  torch.add(currentOutput, currentOutput, F)
  table.insert(netv2Inp, currentOutput)
  currentOutput = self.trunk2.modules[6]:forward(currentOutput)

  F = self.neth2s[2]:forward(self.refs[2].output)
  torch.add(currentOutput, currentOutput, F)
  table.insert(netv2Inp, currentOutput)
  currentOutput = self.trunk2.modules[7]:forward(currentOutput)
  currentOutput = self.trunk2.modules[8]:forward(currentOutput)

  F = self.refs[1].output
  F = self.neth2s[1]:forward(F)
  torch.add(currentOutput, currentOutput, F)
  table.insert(netv2Inp, currentOutput)

  self.netv2Inp = netv2Inp

  currentOutput = self.refs2[0]:forward(currentOutput)
  for k = 1,#self.refs2 do
    local F = neth2Inp[5-k]
    self.inps2[k] = {F,currentOutput}
    currentOutput = self.refs2[k]:forward(self.inps[k])
  end

  self.output = currentOutput
  return self.output
end

--------------------------------------------------------------------------------
-- function: backward
function SharpMask:backward(input,gradOutput)

  -- backward pass for refinement 2
  local currentGrad = gradOutput
  for i = #self.refs,1,-1 do
    currentGrad =self.refs2[i]:backward(self.inps2[i],currentGrad)
    currentGrad = currentGrad[2]
  end
  currentGrad =self.refs2[0]:backward(self.netv2Inp[4],currentGrad)

  -- backward pass for trunk 2 and horizontal 2
  self.neth2s[1]:backward(self.inps[1], currentGrad)
  currentGrad = self.trunk2.modules[8]:backward(self.trunk2.modules[7].output, currentGrad)
  currentGrad = currentGrad[2]

  currentGrad = self.trunk2.modules[7]:backward(self.netv2Inp[3], currentGrad)
  currentGrad = currentGrad[2]

  self.neth2s[2]:backward(self.inps[2], currentGrad)
  currentGrad = self.trunk2.modules[6]:backward(self.netv2Inp[2], currentGrad)
  
  self.neth2s[3]:backward(self.inps[3], currentGrad)
  currentGrad = self.trunk2.modules[5]:backward(self.trunk2.modules[4].output, currentGrad)
  currentGrad = self.trunk2.modules[4]:backward(self.netv2Inp[1], currentGrad)

  self.neth2s[4]:backward(self.inps[4], currentGrad)
  currentGrad = self.trunk2.modules[3]:backward(self.trunk2.modules[2].output, currentGrad)
  currentGrad = self.trunk2.modules[2]:backward(self.trunk2.modules[1].output, currentGrad)
  currentGrad = self.trunk2.modules[1]:backward(input, currentGrad)

  self.gradInput = currentGrad
  return currentGrad
end

--------------------------------------------------------------------------------
-- function: zeroGradParameters
function SharpMask:zeroGradParameters()
  for k,v in pairs(self.refs) do self.refs[k]:zeroGradParameters() end
end

--------------------------------------------------------------------------------
-- function: updateParameters
function SharpMask:updateParameters(lr)
  for k,n in pairs(self.refs) do self.refs[k]:updateParameters(lr) end
end

--------------------------------------------------------------------------------
-- function: training
function SharpMask:training()
  self.trunk:training();self.scoreBranch:training();self.maskBranchDM:training()
  for k,n in pairs(self.refs) do self.refs[k]:training() end
end

--------------------------------------------------------------------------------
-- function: evaluate
function SharpMask:evaluate()
  self.trunk:evaluate();self.scoreBranch:evaluate();self.maskBranchDM:evaluate()
  for k,n in pairs(self.refs) do self.refs[k]:evaluate() end
end

--------------------------------------------------------------------------------
-- function: to cuda
function SharpMask:cuda()
  self.trunk:cuda();self.scoreBranch:cuda();self.maskBranchDM:cuda()
  for k,n in pairs(self.refs) do self.refs[k]:cuda() end
end

--------------------------------------------------------------------------------
-- function: to float
function SharpMask:float()
  self.trunk:float();self.scoreBranch:float();self.maskBranchDM:float()
  for k,n in pairs(self.refs) do self.refs[k]:float() end
end

--------------------------------------------------------------------------------
-- function: set number of proposals for inference
function SharpMask:setnpinference(np)
  local vsz = self.refs[0].modules[2].size
  self.refs[0].modules[2]:resetSize(np,vsz[2],vsz[3],vsz[4])
end

--------------------------------------------------------------------------------
-- function: inference (used for full scene inference)
function SharpMask:inference(np)
  self:evaluate()

  -- remove last view
  self.refs[#self.refs]:remove()

  -- remove ZeroPaddings
  self.trunk.modules[8]=nn.Identity():cuda()
  for k = 1, #self.refs do
    local m = self.refs[k].modules[1].modules[1].modules[1]
    if torch.typename(m):find('SpatialZeroPadding') then
      self.refs[k].modules[1].modules[1].modules[1]=nn.Identity():cuda()
    end
  end

  -- remove horizontal links, as they are applied convolutionally
  for k = 1, #self.refs do
    self.refs[k].modules[1].modules[1]=nn.Identity():cuda()
  end

  -- modify number of batch to np (number of proposals)
  self:setnpinference(np)

  -- transform trunk and score branch to conv
  utils.linear2convTrunk(self.trunk,self.fSz)
  utils.linear2convHead(self.scoreBranch)
  self.maskBranchDM = self.maskBranchDM.modules[1]

  self:cuda()
end

--------------------------------------------------------------------------------
-- function: clone
function SharpMask:clone(...)
  local f = torch.MemoryFile("rw"):binary()
  f:writeObject(self); f:seek(1)
  local clone = f:readObject(); f:close()

  if select('#',...) > 0 then
    clone.trunk:share(self.trunk,...)
    clone.maskBranchDM:share(self.maskBranchDM,...)
    clone.scoreBranch:share(self.scoreBranch,...)
    for k,n in pairs(self.netvs) do clone.netvs[k]:share(self.netvs[k],...)end
    for k,n in pairs(self.neths) do clone.neths[k]:share(self.neths[k],...) end
    for k,n in pairs(self.refs)  do clone.refs[k]:share(self.refs[k],...) end
  end

  return clone
end

return nn.SharpMask