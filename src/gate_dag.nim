# import std/sequtils
import ./gate_funcs
import ./bitty
import std/sugar
import std/random
import std/sequtils
import std/strformat

randomize()

type
  GateRef* {.acyclic.} = ref GateObj
  GateObj* = object
    value*: BitArray
    evaluated*: bool

    inputs*: array[2, GateRef]
    inputs_cache*: array[2, GateRef]

    outputs*: seq[GateRef]

    function*: GateFunc
    function_cache*: GateFunc

  Graph* = object
    inputs*: seq[GateRef]
    gates*: seq[GateRef]
    outputs*: seq[GateRef]


proc eval(gate: GateRef) =
  if not gate.evaluated:
    assert gate.inputs[0].evaluated and gate.inputs[1].evaluated, "Inputs must be evaluated before gate"

    gate.value = gate.function.eval(
      gate.inputs[0].value,
      gate.inputs[1].value
    )
    gate.evaluated = true

proc eval*(graph: var Graph, bitpacked_inputs: seq[BitArray]): seq[BitArray] =

  for g in graph.gates:
    g.evaluated = false
  for o in graph.outputs:
    o.evaluated = false
  for i in graph.inputs:
    i.evaluated = true

  var output: seq[BitArray]

  for (i, v) in zip(graph.inputs, bitpacked_inputs):
    i.value = v

  for i, g in graph.gates:
    g.eval()

  for o in graph.outputs:
    o.eval()
    output.add(o.value)

  return output

proc add_input*(graph: var Graph) =
  graph.inputs.add(GateRef(evaluated: true))

proc connect*(new_input, gate: GateRef, input_idx: int) =
  new_input.outputs.add(gate)
  gate.inputs[input_idx] = new_input

proc replace_input*(gate, old_input, new_input: GateRef) =
  old_input.outputs.del(old_input.outputs.find(gate))
  connect(new_input, gate, gate.inputs.find(old_input))

proc add_output*(graph: var Graph) =
  assert graph.inputs.len > 0, "Inputs must be added before outputs"

  let g = GateRef(evaluated: false)
  for i in 0..1:
    var random_input_gate = sample(graph.inputs)
    connect(random_input_gate, g, input_idx = i)
    
  graph.outputs.add(g)

proc add_random_gate*(graph: var Graph) =
  # we split an edge between two existing gates with a new gate
  # but this leaves one undetermined input on the new gate. This
  # input is chosen randomly from gates before the new gate in
  # the graph.

  let random_gate_idx = rand(0 ..< (graph.gates.len + graph.outputs.len))
  let new_gate_insertion_idx = min(random_gate_idx, graph.gates.len)
  let input_edge_to_split = rand(0..1)

  var random_gate = (graph.gates & graph.outputs)[random_gate_idx]
  var upstream_gate = random_gate.inputs[input_edge_to_split]
  var new_gate= GateRef(function: GateFunc.gf_NAND)

  random_gate.replace_input(upstream_gate, new_gate)
  connect(upstream_gate, new_gate, input_idx=0)

  let valid_inputs = (graph.inputs & graph.gates)[0 ..< (new_gate_insertion_idx + graph.inputs.len)]
  connect(sample(valid_inputs), new_gate, input_idx=1)

  graph.gates.insert(new_gate, new_gate_insertion_idx)

proc boolseq_to_uint64(boolseq: seq[bool]): uint64 =
  var output: uint64 = 0
  for i, bit in boolseq:
    if bit:
      output = output or (1.uint64 shl i)
  return output

proc unpack_bitarrays_to_uint64*(packed: seq[BitArray]): seq[uint64] =
  # seq(output_bitcount)[BitArray] --> seq(num_addresses)[uint64]
  var unpacked: seq[uint64] = newSeq[uint64](packed[0].len)
  for idx in 0 ..< packed[0].len:
    var bits: seq[bool] = newSeq[bool](packed.len)
    for i in 0 ..< packed.len:
      bits[i] = packed[i].unsafeGet(idx)
    unpacked[idx] = boolseq_to_uint64(bits)

  return unpacked

proc stage_function_mutation*(gate: GateRef) =
  gate.function_cache = gate.function
  let available_functions = collect(newSeq):
    for f in GateFunc.low .. GateFunc.high:
      if f != gate.function: f
  gate.function = sample(available_functions)

proc undo_function_mutation*(gate: GateRef) =
  gate.function = gate.function_cache

proc stage_input_mutation*(gate: GateRef, graph: Graph) =
  gate.inputs_cache = gate.inputs
  let random_gate_idx: int = graph.gates.find(gate)
  let valid_inputs = (graph.inputs & graph.gates)[0 ..< (random_gate_idx + graph.inputs.len)]
  for i in 0..1:
    gate.replace_input(gate.inputs[i], sample(valid_inputs))

proc undo_input_mutation*(gate: GateRef) =
  for i in 0..1:
    gate.replace_input(gate.inputs[i], gate.inputs_cache[i])
