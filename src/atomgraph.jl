using GraphPlot
using Colors
using Cairo
using Fontconfig

"""
    AtomGraph{A}

A type representing an atomic structure as a graph (`gr`).

# Fields
- `graph::SimpleWeightedGraph{<:Integer,<:Real}`: the graph representing the structure. See
  [`build_graph`](@ref) for more on generating the weights.
- `elements::Vector{String}`: list of elemental symbols corresponding to each node of the
  graph
- `laplacian::Matrix{<:Real}`: Normalized graph Laplacian matrix, stored to speed up
  convolution operations by avoiding recomputing it every pass.
- `id::String`: Optional, an identifier, e.g. to correspond with tags/labels of an imported
  dataset.
- `structure::A`: the original representation from which this AtomGraph was created
"""
mutable struct AtomGraph{A}
    graph::SimpleWeightedGraph{<:Integer,<:Real}
    elements::Vector{String}
    laplacian::Matrix{<:Real} # wanted to use Graphs.LinAlg.NormalizedGraphLaplacian but seems this doesn't support weighted graphs?
    structure::A
    id
end

# one without features or featurization initialized yet
function AtomGraph(
    graph::SimpleWeightedGraph{B,C},
    elements::Vector{String},
    structure,
    id::String = "",
) where {C<:Real,B<:Integer}
    # check that elements is the right length
    num_atoms = size(graph)[1]
    @assert length(elements) == num_atoms "Element list length doesn't match graph size!"

    # this was previously C.(normalized_laplacian(graph)) - won't that potentially give rise to compatibility issues if C is a custom type?
    laplacian = normalized_laplacian(graph)
    AtomGraph(graph, elements, laplacian, structure, id)
end

# if the original structure is a graph...
AtomGraph(graph::SimpleWeightedGraph, elements::Vector{String}, id::String = "") =
    AtomGraph(graph, elements, graph, id)

# initialize directly from adjacency matrix
AtomGraph(adj::Array{R}, elements::Vector{String}, id::String = "") where {R<:Real} =
    AtomGraph(SimpleWeightedGraph(adj), elements, id)

AtomGraph(
    adj::Array{R},
    elements::Vector{String},
    structure,
    id::String = "",
) where {R<:Real} = AtomGraph(SimpleWeightedGraph(adj), elements, structure, id)

"""
    AtomGraph(input_file_path, id = splitext(input_file_path)[begin]; output_file_path = nothing, overwrite_file = false, use_voronoi = false, cutoff_radius = 8.0, max_num_nbr = 12, dist_decay_func = inverse_square)

Construct an AtomGraph object from a structure file.

# Required Arguments
- `input_file_path::String`: path to file containing structure (must be readable by ASE.io.read)

# Optional Arguments
- `id::String`: ID associated with structure (e.g. identifier from online database). Defaults to name of input file if undefined.
- `output_file_path = nothing`: If provided, structure will be serialized to file at this location
- `overwrite_file::Bool = false`: whether to overwrite an existing file at `output_file_path`
- `use_voronoi::Bool = false`: Whether to build neighbor lists using Voronoi decompositions
- `cutoff_radius::Real = 8.0`: If not using Voronoi neighbor lists, longest allowable distance to a neighbor, in Angstroms
- `max_num_nbr::Integer = 12`: If not using Voronoi neighbor lists, largest allowable number of neighbors
- `dist_decay_func = inverse_square`: Function by which to assign edge weights according to distance between neighbors

# Note
`max_num_nbr` is a "soft" limit – if multiple neighbors are at the same distance, the full neighbor list may be longer.
"""
function AtomGraph(
    input_file_path::String,
    id::String = splitext(input_file_path)[begin];
    output_file_path::Union{String,Nothing} = nothing,
    overwrite_file::Bool = false,
    use_voronoi::Bool = false,
    cutoff_radius::Real = 8.0,
    max_num_nbr::Integer = 12,
    dist_decay_func::Function = inverse_square,
)

    local ag

    if !isfile(input_file_path)
        @warn "$input_file_path does not exist. Cannot build graph from a non-existent file."
        return missing
    end

    if splitext(input_file_path)[end] == ".jls" # deserialize
        ag = deserialize(input_file_path)
        ag.id = id

    else # try actually building the graph
        try
            adj_mat, elements, structure = build_graph(
                input_file_path,
                use_voronoi = use_voronoi,
                cutoff_radius = cutoff_radius,
                max_num_nbr = max_num_nbr,
                dist_decay_func = dist_decay_func,
            )
            ag = AtomGraph(adj_mat, elements, structure, id)
        catch
            @warn "Unable to build graph for $input_file_path"
            return missing
        end
    end

    to_serialize = !isnothing(output_file_path)
    if to_serialize
        if isfile(output_file_path) && !(overwrite_file)
            @info "Output file already exists, and `overwrite_file` is set to false.\nIf you want to overwrite the existing graph, set `overwrite=true`, or remove the existing file and retry."
        else
            serialize(output_file_path, ag)
        end
    end

    return ag
end

"""
    AtomGraph(crys::Crystal; id="", cutoff_radius = 8.0, max_num_nbr = 12, dist_decay_func = inverse_square)

Construct an AtomGraph object from a Crystal object (defined in Xtals.jl). For now, only supports cutoff-based graph building.

# Required Arguments
- `crys::Crystal`: Crystal from which to build the graph

# Optional Arguments
- `id::String`: ID associated with structure (e.g. identifier from online database). Defaults to the empty string.
- `cutoff_radius::Real = 8.0`: Longest allowable distance to a neighbor, in Angstroms
- `max_num_nbr::Integer = 12`: Largest allowable number of neighbors
- `dist_decay_func = inverse_square`: Function by which to assign edge weights according to distance between neighbors

# Note
`max_num_nbr` is a "soft" limit – if multiple neighbors are at the same distance, the full neighbor list may be longer.
"""
function AtomGraph(
    crys::Crystal;
    id::String = "",
    cutoff_radius::Real = 8.0,
    max_num_nbr::Integer = 12,
    dist_decay_func::Function = inverse_square,
)
    adj_mat, elements = build_graph(
        crys;
        cutoff_radius = cutoff_radius,
        max_num_nbr = max_num_nbr,
        dist_decay_func = dist_decay_func,
    )
    ag = AtomGraph(adj_mat, elements, crys, id)
end

# helper fcn
function get_elements(mol::GraphMol)
    String.(map(1:atomcount(mol)) do n
        atom = getatom(mol, n)
        s = atomsymbol(atomnumber(atom))
    end)
    #     String.([mol.nodeattrs[i].symbol for i in 1:length(mol.nodeattrs)])
end

"""
    AtomGraph(mol::GraphMol, id="")

Build an AtomGraph from a GraphMol object. Currently does not have access to any 3D structure, so resulting graph is unweighted.

Eventually, could have a version of this that connects to e.g. PubChem or ChemSpider to try to fetch 3D structures, in which case other kwargs for actual graph-building will become relevant.
"""
function AtomGraph(mol::GraphMol, id::String = "")
    # TODO: use weighted graphs
    if MolecularGraph.atomcount(mol) == 1
        @info "A single-node graph is not very interesting...and also hard to compute a laplacian for."
        return missing
    end
    sg = SimpleGraph(MolecularGraph.atomcount(mol))
    add_edge!.(Ref(sg), Edge.(mol.edges))
    elements = get_elements(mol)
    AtomGraph(collect(adjacency_matrix(sg)), elements, mol, id)
end

# pretty printing, short version
function Base.show(io::IO, ag::AtomGraph)
    st = "$(typeof(ag)) $(ag.id) with $(nv(ag.graph)) nodes, $(ne(ag.graph)) edges"
    print(io, st)
end

# pretty printing, long version
function Base.show(io::IO, ::MIME"text/plain", ag::AtomGraph)
    st = "$(typeof(ag)) $(ag.id) with $(nv(ag.graph)) nodes, $(ne(ag.graph)) edges\n\tatoms: $(ag.elements)"
    print(io, st)
end


"""
    normalized_laplacian(graph)

Compute the normalized graph Laplacian matrix of the input graph, defined as

``I - D^{-1/2} A D^{-1/2}``

where ``A`` is the adjacency matrix and ``D`` is the degree matrix.
"""
function normalized_laplacian(g::G) where {G<:Graphs.AbstractGraph}
    a = adjacency_matrix(g)
    d = vec(sum(a, dims = 1))
    inv_sqrt_d = diagm(0 => d .^ (-0.5f0))
    laplacian = Float32.(I - inv_sqrt_d * a * inv_sqrt_d)
    !any(isnan, laplacian) || throw(
        ArgumentError(
            "NaN values in graph Laplacian! This is most likely due to atomic separations larger than the specified cutoff distance leading to block zeros in the adjacency matrix...try increasing the cutoff distance or inspecting your structure to ensure the file is correct.",
        ),
    )
    return laplacian
end


normalized_laplacian(ag::AtomGraph) = ag.laplacian

elements(ag::AtomGraph) = ag.elements

# now visualization stuff...

"Get a list of colors to use for graph visualization."
function graph_colors(atno_list, seed_color = colorant"cyan4")
    atom_types = unique(atno_list)
    atom_type_inds = Dict(atom_types[i] => i for i = 1:length(atom_types))
    color_inds = [atom_type_inds[i] for i in atno_list]
    colors = distinguishable_colors(length(atom_types), seed_color)
    return colors[color_inds]
end


"Helper function for sorting because edge ordering isn't preserved when converting to SimpleGraph."
function lt_edge(
    e1::SimpleWeightedGraphs.SimpleWeightedEdge{<:Integer,<:Real},
    e2::SimpleWeightedGraphs.SimpleWeightedEdge{<:Integer,<:Real},
)
    if e1.src < e2.src
        return true
    elseif e1.dst < e2.dst
        return true
    else
        return false
    end
end


"Compute edge widths (proportional to weights on graph) for graph visualization."
function graph_edgewidths(ag::AtomGraph)
    edgewidths = []
    edges_sorted = sort([e for e in edges(ag.graph)], lt = lt_edge)
    for e in edges_sorted
        append!(edgewidths, e.weight)
    end
    return edgewidths
end


"Visualize a given graph."
function visualize(ag::AtomGraph)
    # gplot doesn't work on weighted graphs
    sg = SimpleGraph(adjacency_matrix(ag.graph))
    plt = gplot(
        sg,
        nodefillc = graph_colors(ag.elements),
        nodelabel = ag.elements,
        edgelinewidth = graph_edgewidths(ag),
    )
    display(plt)
end
