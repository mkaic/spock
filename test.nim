import ./gate_dag
import pixie as pix
import std/strformat
import std/sequtils
import std/math

var branos = pix.read_image("branos.png")

const
  width = 128
  height = 128
  channels = 3
  gates = 256
  lookback = gates div 8
  n_mutations = 1
  deque_len = 50


branos = branos.resize(width, height)

let (batches, bitcount) = make_bitpacked_int64_batches(
  height = height,
  width = width, 
  channels = channels
  )

echo bitcount
var graph = Graph()

graph.add_inputs(bitcount)
for i in 0 ..< layers:
  graph.add_random_gate(layer_size, last = lookback)

for i in 0 ..< output_bitcount:
  graph.add_random_gate(8, output = true, last = lookback)

echo &"Graph has {graph.gates.len} gates"

var error = 255.0
var improved: seq[int8]

for i in 1..10_000:
  var gate_cache: seq[Gate]
  var old_inputs_cache: seq[array[2, Gate]]
  for i in 1..n_mutations:
    var (g, i) = graph.stage_mutation(last = lookback)
    gate_cache.add(g)
    old_inputs_cache.add(i)

  var outputs: seq[int64] # len = 8 * num_batches
  for batch_idx in 0 ..< batches.len div bitcount:
    let batch = batches[batch_idx * bitcount ..< (batch_idx + 1) * bitcount]
    outputs &= graph.eval(batch)

  let output_image = unpack_int64_outputs_to_pixie(
    outputs,
    height = height,
    width = width,
    channels = channels
    )

  let candidate_error = calculate_mae(branos, output_image)

  if candidate_error < error:
    error = candidate_error
    output_image.write_file(&"outputs/{i:04}.png")
    output_image.write_file(&"latest.png")
    improved.add(1)
    let improvement_rate = math.sum[int8](improved).float64 /
        improved.len.float64
    echo &"Error: {error:0.3f} at step {i}. Improvement rate: {improvement_rate:0.5f}"
  elif candidate_error == error:
    improved.add(0)
  else:
    improved.add(0)
    for (gate, old_inputs) in zip(gate_cache, old_inputs_cache):
      gate.undo_mutation(old_inputs)

  if improved.len > deque_len:
    improved.del(0)


