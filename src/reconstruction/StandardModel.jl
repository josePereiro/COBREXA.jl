"""
    add_reactions!(model::StandardModel, rxns::Vector{Reaction})

Add `rxns` to `model` based on reaction `id`.
"""
function add_reactions!(model::StandardModel, rxns::Vector{Reaction})
    for rxn in rxns
        model.reactions[rxn.id] = rxn
    end
    nothing
end

"""
    add_reaction!(model::StandardModel, rxn::Reaction)

Add `rxn` to `model` based on reaction `id`.
"""
add_reaction!(model::StandardModel, rxn::Reaction) = add_reactions!(model, [rxn])

"""
    add_metabolites!(model::StandardModel, mets::Vector{Metabolite})

Add `mets` to `model` based on metabolite `id`.
"""
function add_metabolites!(model::StandardModel, mets::Vector{Metabolite})
    for met in mets
        model.metabolites[met.id] = met
    end
    nothing
end

"""
    add_metabolite!(model::StandardModel, met::Metabolite)

Add `met` to `model` based on metabolite `id`.
"""
add_metabolite!(model::StandardModel, met::Metabolite) = add_metabolites!(model, [met])

"""
    add_genes!(model::StandardModel, genes::Vector{Gene})

Add `genes` to `model` based on gene `id`.
"""
function add_genes!(model::StandardModel, genes::Vector{Gene})
    for gene in genes
        model.genes[gene.id] = gene
    end
    nothing
end

"""
    add_gene!(model::StandardModel, genes::Gene)

Add `gene` to `model` based on gene `id`.
"""
add_gene!(model::StandardModel, gene::Gene) = add_genes!(model, [gene])

"""
    @add_reactions!(model::Symbol, ex::Expr)

Shortcut to add multiple reactions and their lower and upper bounds

Call variants
-------------
```
@add_reactions! model begin
    reaction_name, reaction
end

@add_reactions! model begin
    reaction_name, reaction, lower_bound
end

@add_reactions! model begin
    reaction_name, reaction, lower_bound, upper_bound
end
```

Examples
--------
```
@add_reactions! model begin
    "v1", nothing → A, 0, 500
    "v2", A ↔ B + C, -500
    "v3", B + C → nothing
end
```
"""
macro add_reactions!(model::Symbol, ex::Expr)
    model = esc(model)
    all_reactions = Expr(:block)
    for line in MacroTools.striplines(ex).args
        args = line.args
        id = esc(args[1])
        reaction = esc(args[2])
        push!(all_reactions.args, :(r = $reaction))
        push!(all_reactions.args, :(r.id = $id))
        if length(args) == 3
            lb = args[3]
            push!(all_reactions.args, :(r.lb = $lb))
        elseif length(args) == 4
            lb = args[3]
            ub = args[4]
            push!(all_reactions.args, :(r.lb = $lb))
            push!(all_reactions.args, :(r.ub = $ub))
        end
        push!(all_reactions.args, :(add_reaction!($model, r)))
    end
    return all_reactions
end

"""
    remove_genes!(
        model::StandardModel,
        ids::Vector{String};
        knockout_reactions::Bool = false,
    )

Remove all genes with `ids` from `model`. If `knockout_reactions` is true, then also
constrain reactions that require the genes to function to carry zero flux.

# Example
```
remove_genes!(model, ["g1", "g2"])
```
"""
function remove_genes!(
    model::StandardModel,
    gids::Vector{String};
    knockout_reactions::Bool = false,
)
    if knockout_reactions
        rm_reactions = String[]
        for (rid, r) in model.reactions
            if !isnothing(r.grr) &&
               all(any(in.(gids, Ref(conjunction))) for conjunction in r.grr)
                push!(rm_reactions, rid)
            end
        end
        pop!.(Ref(model.reactions), rm_reactions)
    end
    pop!.(Ref(model.genes), gids)
    nothing
end

"""
    remove_gene!(
        model::StandardModel,
        id::Vector{String};
        knockout_reactions::Bool = false,
    )

Remove gene with `id` from `model`. If `knockout_reactions` is true, then also
constrain reactions that require the genes to function to carry zero flux.

# Example
```
remove_gene!(model, "g1")
```
"""
remove_gene!(model::StandardModel, gid::String; knockout_reactions::Bool = false) =
    remove_genes!(model, [gid]; knockout_reactions = knockout_reactions)


@_change_bounds_fn StandardModel String inplace begin
    isnothing(lower) || (model.reactions[rxn_id].lb = lower)
    isnothing(upper) || (model.reactions[rxn_id].ub = upper)
    nothing
end

@_change_bounds_fn StandardModel String inplace plural begin
    for (i, l, u) in zip(rxn_ids, lower, upper)
        change_bound!(model, i, lower = l, upper = u)
    end
end

@_change_bounds_fn StandardModel String begin
    change_bounds(model, [rxn_id], lower = [lower], upper = [upper])
end

@_change_bounds_fn StandardModel String plural begin
    n = copy(model)
    n.reactions = copy(model.reactions)
    for i in rxn_ids
        n.reactions[i] = copy(n.reactions[i])
    end
    change_bounds!(n, rxn_ids, lower = lower, upper = upper)
    return n
end

@_remove_fn reaction StandardModel String inplace begin
    if !(reaction_id in reactions(model))
        @_models_log @info "Reaction $reaction_id not found in model."
    else
        delete!(model.reactions, reaction_id)
    end
    nothing
end

@_remove_fn reaction StandardModel String inplace plural begin
    remove_reaction!.(Ref(model), reaction_ids)
    nothing
end

@_remove_fn reaction StandardModel String begin
    remove_reactions(model, [reaction_id])
end

@_remove_fn reaction StandardModel String plural begin
    n = copy(model)
    n.reactions = copy(model.reactions)
    remove_reactions!(n, reaction_ids)
    return n
end

@_remove_fn metabolite StandardModel String inplace begin
    if !(metabolite_id in metabolites(model))
        @_models_log @info "Metabolite $metabolite_id not found in model."
    else
        delete!(model.metabolites, metabolite_id)
    end
    nothing
end

@_remove_fn metabolite StandardModel String inplace plural begin
    remove_metabolite!.(Ref(model), metabolite_ids)
    nothing
end

@_remove_fn metabolite StandardModel String begin
    remove_metabolites(model, [metabolite_id])
end

@_remove_fn metabolite StandardModel String plural begin
    n = copy(model)
    n.reactions = copy(model.reactions)
    n.metabolites = copy(model.metabolites)
    remove_metabolites!(n, metabolite_ids)
    return n
end
