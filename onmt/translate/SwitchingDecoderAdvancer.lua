--[[ DecoderAdvancer is an implementation of the interface Advancer for
  specifyinghow to advance one step in decoder.
--]]
local SwitchingDecoderAdvancer = torch.class('SwitchingDecoderAdvancer', 'Advancer')

--[[ Constructor.

Parameters:

  * `decoder` - an `onmt.Decoder` object.
  * `batch` - an `onmt.data.Batch` object.
  * `context` - encoder output (batch x n x rnnSize).
  * `max_sent_length` - optional, maximum output sentence length.
  * `max_num_unks` - optional, maximum number of UNKs.
  * `decStates` - optional, initial decoder states.
  * `dicts` - optional, dictionary for additional features.

--]]
function SwitchingDecoderAdvancer:__init(decoder, batch, context, max_sent_length,
    max_num_unks, decStates, dicts, map, multilabel)
  self.decoder = decoder
  self.batch = batch
  self.context = context
  self.max_sent_length = max_sent_length or math.huge
  self.max_num_unks = max_num_unks or math.huge
  self.decStates = decStates or onmt.utils.Tensor.initTensorTable(
    decoder.args.numEffectiveLayers,
    onmt.utils.Cuda.convert(torch.Tensor()),
    { self.batch.size, decoder.args.rnnSize })
  self.dicts = dicts
  self.map = map
  self.multilabel = multilabel
end

--[[Returns an initial beam.

Returns:

  * `beam` - an `onmt.translate.Beam` object.

--]]
function SwitchingDecoderAdvancer:initBeam()
  local tokens = onmt.utils.Cuda.convert(torch.IntTensor(self.batch.size)):fill(onmt.Constants.BOS)
  local features = {}
  if self.dicts then
    for j = 1, #self.dicts.tgt.features do
      features[j] = torch.IntTensor(self.batch.size):fill(onmt.Constants.EOS)
    end
  end
  local sourceSizes = onmt.utils.Cuda.convert(self.batch.sourceSize)

  -- Define state to be { decoder states, decoder output, context,
  -- attentions, features, sourceSizes, step, idxsOfSourceWords }.
  local state = { self.decStates, nil, self.context, nil, features, sourceSizes, 1, self.batch:getSourceWords() }
  return onmt.translate.Beam.new(tokens, state)
end

--[[Updates beam states given new tokens.

Parameters:

  * `beam` - beam with updated token list.

]]
function SwitchingDecoderAdvancer:update(beam)
  local state = beam:getState()
  local decStates, decOut, context, _, features, sourceSizes, t, sourceIdxs
    = table.unpack(state, 1, 8)
  local tokens = beam:getTokens()
  local token = tokens[#tokens]
  local inputs
  if #features == 0 then
    inputs = token
  elseif #features == 1 then
    inputs = { token, features[1] }
  else
    inputs = { token }
    table.insert(inputs, features)
  end
  -- all sources are the same size
  --self.decoder:maskPadding(sourceSizes, self.batch.sourceLength)
  decOut, decStates = self.decoder:forwardOne(inputs, decStates, context, decOut)
  t = t + 1
  local softmaxOut = nil -- self.decoder.softmaxAttn.output
  local nextState = {decStates, decOut, context, softmaxOut, nil, sourceSizes, t, sourceIdxs}
  beam:setState(nextState)
end

--[[Expand function. Expands beam by all possible tokens and returns the
  scores.

Parameters:

  * `beam` - an `onmt.translate.Beam` object.

Returns:

  * `scores` - a 2D tensor of size `(batchSize * beamSize, numTokens)`.

]]
function SwitchingDecoderAdvancer:expand(beam)
  local state = beam:getState()
  local decOut = state[2]
  local context = state[3]
  local finalLayer = state[1][#state[1]]
  local sourceIdxs = state[8]
  local zpreds = self.decoder.switcher:forward({context, finalLayer})
  local ptrPreds = self.decoder.ptrGenerator:forward({context, finalLayer})
  local pred = self.decoder.generator:forward(decOut)[1]
  --local out = self.decoder.generator:forward(decOut)
  for b = 1, pred:size(1) do
      if self.map then -- just take argmax prob
          if zpreds[b][1] >= 0.5 then -- a copy
              pred[b]:zero() -- this is kind of stupid from a beam search perspective
              --  marginalize over all copies of same word
              if not self.multilabel then
                  ptrPreds[b]:exp()
              end
              pred[b]:indexAdd(1, sourceIdxs[b], ptrPreds[b])
              pred[b]:log()
          end
      else -- truly marginalize
          pred[b]:add(math.log(1-zpreds[b][1]))
          if self.multilabel then
              ptrPreds[b]:mul(zpreds[b][1])
          else
              ptrPreds[b]:add(math.log(zpreds[b][1]))
          end
          pred[b]:exp()
          if not self.multilabel then
              ptrPreds[b]:exp()
          end
          pred[b]:indexAdd(1, sourceIdxs[b], ptrPreds[b])
          pred[b]:log()
      end
  end

  local features = {}
  -- for j = 2, #out do
  --   local _, best = out[j]:max(2)
  --   features[j - 1] = best:view(-1)
  -- end
  state[5] = features
  --local scores = out[1]
  local scores = pred
  return scores
end

--[[Checks which hypotheses in the beam are already finished. A hypothesis is
  complete if i) an onmt.Constants.EOS is encountered, or ii) the length of the
  sequence is greater than or equal to `max_sent_length`.

Parameters:

  * `beam` - an `onmt.translate.Beam` object.

Returns: a binary flat tensor of size `(batchSize * beamSize)`, indicating
  which hypotheses are finished.

]]
function SwitchingDecoderAdvancer:isComplete(beam)
  local tokens = beam:getTokens()
  local seqLength = #tokens - 1
  local complete = tokens[#tokens]:eq(onmt.Constants.EOS)
  if seqLength > self.max_sent_length then
    complete:fill(1)
  end
  return complete
end

--[[Checks which hypotheses in the beam shall be pruned. We disallow empty
 predictions, as well as predictions with more UNKs than `max_num_unks`.

Parameters:

  * `beam` - an `onmt.translate.Beam` object.

Returns: a binary flat tensor of size `(batchSize * beamSize)`, indicating
  which beams shall be pruned.

]]
function SwitchingDecoderAdvancer:filter(beam)
  local tokens = beam:getTokens()
  local numUnks = onmt.utils.Cuda.convert(torch.zeros(tokens[1]:size(1)))
  for t = 1, #tokens do
    local token = tokens[t]
    numUnks:add(onmt.utils.Cuda.convert(token:eq(onmt.Constants.UNK):double()))
  end

  -- Disallow too many UNKs
  local pruned = numUnks:gt(self.max_num_unks)

  -- Disallow empty hypotheses
  if #tokens == 2 then
    pruned:add(tokens[2]:eq(onmt.Constants.EOS))
  end
  return pruned:ge(1)
end

return SwitchingDecoderAdvancer
