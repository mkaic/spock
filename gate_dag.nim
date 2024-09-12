# import std/sequtils
import std/sugar
import std/random
import std/bitops
import std/strutils
import pixie as pix

randomize()

type
  Gate* = ref object
    value: int64
    evaluated: bool
    inputs: array[2, Gate]

  Graph* = object
    inputs: seq[Gate]
    gates*: seq[Gate]
    outputs: seq[Gate]
    mutated_gate: Gate
    unmutated_inputs_cache: array[2, Gate]


proc eval*(gate: Gate): int64 =
  if not gate.evaluated:
    gate.value = bit_not(
      bit_and(
        gate.inputs[0].eval(),
        gate.inputs[1].eval()
      )
    )
    gate.evaluated = true

  return gate.value

proc eval*(graph: var Graph, batched_inputs: seq[seq[int64]]): seq[seq[int64]] =
  for g in graph.gates:
    g.evaluated = false
  for g in graph.outputs:
    g.evaluated = false

  var output: seq[seq[int64]]
  for batch in batched_inputs:
    for i in 0 ..< graph.inputs.len:
      graph.inputs[i].value = batch[i]

    var batch_output: seq[int64]
    for o in graph.outputs:
      batch_output.add(o.eval())
    output.add(batch_output)

  return output

proc choose_random_gate_inputs(gate: Gate, available_inputs: seq[Gate])=
  for i in 0..1:
    gate.inputs[i] = available_inputs[rand(available_inputs.len - 1)]

proc add_input*(graph: var Graph) =
  graph.inputs.add(Gate(value: 0'i64, evaluated: true))

proc add_output*(graph: var Graph) =
  assert graph.inputs.len > 0, "Inputs must be added before outputs"
  assert graph.gates.len == 0, "Outputs must be added before gates"
  let g = Gate(value: 0'i64, evaluated: false)
  choose_random_gate_inputs(g, graph.inputs)
  graph.outputs.add(g)

proc add_random_gate*(
  graph: var Graph,
  lookback: int = 0,
  ) =
  var available_graph_inputs = graph.inputs & graph.gates

  if lookback > 0 and graph.gates.len >= lookback:
    available_graph_inputs = available_graph_inputs[^lookback..^1]

  let g = Gate(value: 0'i64, evaluated: false)
  choose_random_gate_inputs(g, available_graph_inputs)
  graph.gates.add(g)

proc int64_to_binchar_seq(i: int64, bits: int): seq[char] =
  return collect(newSeq):
    for c in to_bin(i, bits): c

proc binchar_seq_to_int64(binchar_seq: seq[char]): int64 =
  return cast[int64](binchar_seq.join("").parse_bin_int())

proc make_inputs*(
  height: int,
  width: int,
  channels: int,
  x_bitcount: int,
  y_bitcount: int,
  c_bitcount: int,
  pos_bitcount: int,
  ): seq[seq[char]] = 
  # returns seq(h*w*c)[seq(input_bitcount)[char]]

  let
    y_as_bits: seq[seq[char]] = collect(newSeq):
      for y in 0 ..< height:
        y.int64_to_binchar_seq(bits = y_bitcount)

    x_as_bits: seq[seq[char]] = collect(newSeq):
      for x in 0 ..< width:
        x.int64_to_binchar_seq(bits = x_bitcount)

    c_as_bits: seq[seq[char]] = collect(newSeq):
      for c in 0 ..< channels:
        c.int64_to_binchar_seq(bits = c_bitcount)

    total_iterations = width * height * channels

  var input_values: seq[seq[char]]
  for idx in 0 ..< total_iterations:
    let
      c: int = idx div (height * width) mod channels
      y: int = idx div (width) mod height
      x: int = idx div (1) mod width

    let
      x_bits: seq[char] = x_as_bits[x]
      y_bits: seq[char] = y_as_bits[y]
      c_bits: seq[char] = c_as_bits[c]

    let pos_bits: seq[char] = x_bits & y_bits & c_bits
    input_values.add(pos_bits)
  return input_values

proc transpose_2d[T](matrix: seq[seq[T]]): seq[seq[T]] =
  let 
    dim0: int = matrix.len
    dim1: int = matrix[0].len

  var transposed: seq[seq[T]]
  for i in 0 ..< dim1:
    var row: seq[T]
    for j in 0 ..< dim0:
      row.add(matrix[j][i])
    transposed.add(row)
  return transposed

proc pack_int64_batches*(unbatched: seq[seq[char]], bitcount: int): seq[seq[int64]] =
  # seq(h*w*c)[seq(input_bitcount)[char]] -> seq(num_batches)[seq(bitcount)[int64]]
  var num_batches: int = unbatched.len div 64 + 1
  var batches: seq[seq[int64]]
  for batch_number in 0 ..< num_batches:
    var char_batch: seq[seq[char]] # will have shape seq(64)[seq(input_bitcount)[char]]
    for intra_batch_idx in 0 ..< 64:
      let idx: int = (batch_number * 64 + intra_batch_idx) mod unbatched.len
      let single_input: seq[char] = unbatched[idx]
      char_batch.add(single_input)

    var int64_batch: seq[int64] # will have shape seq(bitcount)[int64]
    for stack_of_bits in char_batch.transpose_2d(): # seq(input_bitcount)[seq(64)[char]]
      int64_batch.add(binchar_seq_to_int64(stack_of_bits))

    batches.add(int64_batch)
  return batches


proc unpack_int64_batches*(batched: seq[seq[int64]]): seq[seq[char]] =
  # seq(num_batches)[seq(output_bitcount)[int64]] -> seq(h*w*c)[seq(output_bitcount)[char]]
  var unbatched: seq[seq[char]] # will have shape seq(h*w*c)[seq(output_bitcount)[char]]
  for batch in batched: # seq(output_bitcount)[int64]
    var char_batch: seq[seq[char]] # will have shape seq(output_bitcount)[seq(64)[char]]
    for int64_input in batch: # int64
      char_batch.add(int64_input.int64_to_binchar_seq(bits = 64))
    unbatched &= char_batch.transpose_2d() # seq(64)[seq(output_bitcount)[char]]

  return unbatched


proc outputs_to_pixie_image*(
  outputs: seq[seq[char]], # seq(h*w*c)[seq(output_bitcount)[char]]
  height: int,
  width: int,
  channels: int
  ): pix.Image =

  var as_uint8: seq[uint8]
  for stack_of_bits in outputs:
    as_uint8.add(
      cast[uint8](
        binchar_seq_to_int64(stack_of_bits)
        )
      )

  var output_image = pix.new_image(width, height)

  for y in 0 ..< height:
    for x in 0 ..< width:
      var rgb: array[3, uint8]
      for c in 0 ..< channels:
        let idx = (c * height * width) + (y * width) + x
        rgb[c] = as_uint8[idx]

      output_image.unsafe[x, y] = pix.rgba(rgb[0], rgb[1], rgb[2], 255)

  return output_image

proc calculate_mae*(
  image1: pix.Image,
  image2: pix.Image
  ): float64 =

  var error = 0
  for y in 0 ..< image1.height:
    for x in 0 ..< image1.width:
      let rgb1 = image1.unsafe[x, y]
      let rgb2 = image2.unsafe[x, y]
      error += abs(rgb1.r.int - rgb2.r.int)
      error += abs(rgb1.g.int - rgb2.g.int)
      error += abs(rgb1.b.int - rgb2.b.int)

  return error.float64 / (image1.width.float64 * image1.height.float64 * 3.0)


proc stage_mutation*(graph: var Graph, lookback: int) =
  let available_gates = graph.gates & graph.outputs
  let random_idx = rand(0..<available_gates.len)
  var gate = available_gates[random_idx]

  let total_idx = (graph.inputs.len - 1) + random_idx
  var available_inputs = graph.inputs & graph.gates & graph.outputs

  available_inputs = available_inputs[0..<total_idx]

  if lookback > 0 and available_inputs.len >= lookback:
    available_inputs = available_inputs[^lookback..^1]

  let old_inputs = gate.inputs
  choose_random_gate_inputs(gate, available_inputs)

  graph.mutated_gate = gate
  graph.unmutated_inputs_cache = old_inputs

proc undo_mutation*(graph: var Graph) =
  var gate = graph.mutated_gate
  for i in 0..1:
    gate.inputs[i] = graph.unmutated_inputs_cache[i]
