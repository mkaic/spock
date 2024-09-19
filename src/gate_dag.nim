# import std/sequtils
import ./gate_funcs
import ./bitty
import std/sugar
import std/random
import std/sequtils
import std/strformat
import std/tables
import std/hashes
import std/algorithm

randomize()

type
  GateRef* {.acyclic.} = ref object
    value*: BitArray
    evaluated*: bool

    inputs*: seq[GateRef]
    inputs_cache*: seq[GateRef]

    outputs*: seq[GateRef]

    function*: GateFunc = gf_NAND
    function_cache*: GateFunc

    id*: int

  Graph* = object
    inputs*: seq[GateRef]
    gates*: seq[GateRef]
    outputs*: seq[GateRef]
    id_autoincrement: int = 0

proc hash(gate: GateRef): Hash =
  return hash(gate.id)

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

  for g in graph.gates:
    g.eval()

  for o in graph.outputs:
    o.eval()
    output.add(o.value)

  return output

proc kahn_topo_sort*(graph: var Graph) =
  var incoming_edges: Table[GateRef, int]
  var pending: seq[GateRef] = newSeq[GateRef]()
  var sorted: seq[GateRef] = newSeq[GateRef]()

  for g in (graph.outputs & graph.gates & graph.inputs):
    incoming_edges[g] = g.inputs.len
    echo "incoming_edges: ", incoming_edges[g]
    if incoming_edges[g] == 0:
      pending.add(g)

  echo "pending len: ", pending.len

  while pending.len > 0:

    let next_gate = pending[0]
    pending.del(0)
    sorted.add(next_gate)
    
    for o in next_gate.outputs:
      incoming_edges[o] -= 1
      if incoming_edges[o] == 0:
        pending.add(o)


  assert sorted.len == graph.outputs.len + graph.gates.len + graph.inputs.len, &"Graph is not connected, and only has len {sorted.len} instead of {graph.outputs.len + graph.gates.len + graph.inputs.len}"
  assert all(sorted, proc (g: GateRef): bool = incoming_edges[g] == 0), "Graph is not acyclic"

  sorted = collect:
    for g in sorted:
      if g in graph.gates: g


proc add_input*(graph: var Graph) =
  graph.inputs.add(GateRef(id: graph.id_autoincrement))
  graph.id_autoincrement += 1

proc connect*(new_input, gate: GateRef) =
  new_input.outputs.add(gate)
  gate.inputs.add(new_input)

proc disconnect*(old_input, gate: GateRef) =
  old_input.outputs.del(old_input.outputs.find(gate))
  gate.inputs.del(gate.inputs.find(old_input))

proc replace_input*(gate, old_input, new_input: GateRef) =
  disconnect(old_input, gate)
  connect(new_input, gate)

proc add_descendants*(gate: GateRef, seen: var seq[GateRef]) =
  for o in gate.outputs:
    if o notin seen:
      seen.add(o)
      add_descendants(o, seen)

proc descendants*(gate: GateRef): seq[GateRef] =
  var descendants = newSeq[GateRef]()
  add_descendants(gate, descendants)
  return descendants

proc add_output*(graph: var Graph) =
  assert graph.inputs.len > 0, "Inputs must be added before outputs"

  let g = GateRef(id: graph.id_autoincrement)
  graph.id_autoincrement += 1

  for i in 0..1:
    connect(sample(graph.inputs), g)
    
  graph.outputs.add(g)

proc add_random_gate*(graph: var Graph) =
  # we split an edge between two existing gates with a new gate
  # but this leaves one undetermined input on the new gate. This
  # input is chosen randomly from gates before the new gate in
  # the graph.

  var random_gate = sample(graph.gates & graph.outputs)
  let input_edge_to_split = rand(0..1)
  var upstream_gate = random_gate.inputs[input_edge_to_split]
   
  var new_gate= GateRef(id: graph.id_autoincrement)
  graph.id_autoincrement += 1

  random_gate.replace_input(upstream_gate, new_gate)
  connect(upstream_gate, new_gate)

  let valid_inputs = collect:
    for g in (graph.inputs & graph.gates):
      if g notin (new_gate.descendants() & new_gate.inputs): g
  
  var random_second_input = sample(valid_inputs)
  connect(random_second_input, new_gate)

  graph.gates.add(new_gate)

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
  let possible_inputs = (graph.inputs & graph.gates)
  for i in 0..1:
    let valid_inputs = collect:
      for g in possible_inputs:
        if g notin (gate.descendants() & gate.inputs): g
    var input_gate = sample(valid_inputs)
    gate.replace_input(gate.inputs[i], input_gate)

proc undo_input_mutation*(gate: GateRef) =
  for i in 0..1:
    gate.replace_input(gate.inputs[i], gate.inputs_cache[i])
