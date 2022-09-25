"""
```
\\\\\\\\\\  // //     | COBREXA.jl  v$(COBREXA.COBREXA_VERSION)
 \\\\ \\\\// //      |
  \\\\ \\/ //       | COnstraint-Based Reconstruction
   \\\\  //        | and EXascale Analysis in Julia
   //  \\\\        |
  // /\\ \\\\       | See documentation and examples at:
 // //\\\\ \\\\      | https://lcsb-biocore.github.io/COBREXA.jl
// //  \\\\\\\\\\     |
```

To start up quickly, install your favorite optimizer, load a metabolic model in
a format such as SBML or JSON, and run a metabolic analysis such as the flux
balance analysis:
```
import Pkg; Pkg.add("GLPK")
using COBREXA, GLPK
model = load_model("e_coli_core.xml")
x = flux_balance_analysis_dict(model, GLPK.Optimizer)
flux_summary(x)
```

A complete overview of the functionality can be found in the documentation.
"""
module COBREXA

using Distributed
using DistributedData
using HDF5
using JSON
using JuMP
using LinearAlgebra
using MAT
using MacroTools
using OrderedCollections
using Random
using Serialization
using SparseArrays
using StableRNGs
using Statistics
using DocStringExtensions

import Base: findfirst, getindex, show
import SBML # conflict with Reaction struct name 
import Pkg

# duplicate joinpath(normpath(joinpath(@__DIR__, "..")) to reduce the exported names
include_dependency(joinpath(normpath(joinpath(@__DIR__, "..")), "Project.toml"))
const COBREXA_VERSION = VersionNumber(
    Pkg.TOML.parsefile(joinpath(normpath(joinpath(@__DIR__, "..")), "Project.toml"))["version"],
)

#=
Organize COBREXA into modules to make discovery of functions and data structures
easier. Load order matters inside each module. 
=#

"""
@_export_names()

An internal macro that exports names contained in the module that calls it.
"""
macro _export_names()
    quote
        for sym in names(@__MODULE__, all = true)
            if sym in [Symbol(@__MODULE__), :eval, :include] ||
               startswith(string(sym), ['_', '#'])
                continue
            end
            @eval export $(Expr(:$, :sym))
        end
    end
end

# constants and definitions
include(joinpath("base", "constants.jl"))
include(joinpath("base", "SBOTerms.jl")) # must come before identifiers.jl
include(joinpath("base", "identifiers.jl"))

"""
module Misc

A module that contains miscellaneous structs, macros, and names used by COBREXA
functions generally.
"""
module Misc
using ..COBREXA.DocStringExtensions, ..COBREXA.SparseArrays
import ..COBREXA

include(joinpath("base", "types", "abstract", "Maybe.jl"))
include(joinpath("base", "types", "abstract", "MetabolicModel.jl"))

# helper macros
include(joinpath("base", "logging", "log.jl"))
include(joinpath("base", "macros", "model_wrapper.jl"))
include(joinpath("base", "macros", "is_xxx_reaction.jl"))

# helper functions
include(joinpath("base", "utils", "guesskey.jl"))

COBREXA.@_export_names()
end


"""
module Types

Types used by COBREXA.
"""
module Types
import ..COBREXA
using ..Misc
using ..Misc: _gets, _guesskey
using ..COBREXA: _constants
using ..COBREXA.JSON,
    ..COBREXA.SparseArrays,
    ..COBREXA.DocStringExtensions,
    ..COBREXA.MAT,
    ..COBREXA.HDF5,
    ..COBREXA.SBML,
    ..COBREXA.OrderedCollections

# concrete external models
include(joinpath("base", "types", "JSONModel.jl"))
include(joinpath("base", "types", "HDF5Model.jl"))
include(joinpath("base", "types", "MATModel.jl"))
include(joinpath("base", "types", "SBMLModel.jl"))

# concrete internal models and types
include(joinpath("base", "types", "CoreModel.jl"))
include(joinpath("base", "types", "CoreModelCoupled.jl"))

include(joinpath("base", "types", "Gene.jl"))
include(joinpath("base", "types", "Reaction.jl"))
include(joinpath("base", "types", "Metabolite.jl"))
include(joinpath("base", "types", "StandardModel.jl"))

include(joinpath("base", "types", "Serialized.jl"))

include(joinpath("base", "types", "ReactionStatus.jl"))

# enzyme constrained models 
include(joinpath("base", "types", "Isozyme.jl"))
include(joinpath("base", "types", "wrappers", "GeckoModel.jl"))
include(joinpath("base", "types", "wrappers", "SMomentModel.jl"))

# io types
include(joinpath("base", "types", "FluxSummary.jl"))
include(joinpath("base", "types", "FluxVariabilitySummary.jl"))

COBREXA.@_export_names()
end

"""
module Accessors

Accessors used to query information about models. Use these instead of directly
interrogating the models via their internals.
"""
module Accessors
import ..COBREXA
using ..COBREXA: _constants
using ..Misc
using ..Misc: _maybemap, _default
using ..Types
using ..Types: _json_gene_name, _json_met_name, _json_rxn_name
using ..Misc: _gets, _guesskey

using ..COBREXA.DocStringExtensions,
    ..COBREXA.SparseArrays,
    ..COBREXA.OrderedCollections,
    ..COBREXA.SBML,
    ..COBREXA.Serialization

include(joinpath("base", "accessors", "MetabolicModel.jl"))
include(joinpath("base", "accessors", "CoreModel.jl"))
include(joinpath("base", "accessors", "CoreModelCoupled.jl"))
include(joinpath("base", "accessors", "StandardModel.jl"))
include(joinpath("base", "accessors", "JSONModel.jl"))
include(joinpath("base", "accessors", "MATModel.jl"))
include(joinpath("base", "accessors", "SBMLModel.jl"))
include(joinpath("base", "accessors", "ModelWrapper.jl"))
include(joinpath("base", "accessors", "HDF5Model.jl"))
include(joinpath("base", "accessors", "GeckoModel.jl"))
include(joinpath("base", "accessors", "SMomentModel.jl"))
include(joinpath("base", "accessors", "Serialized.jl"))

# functions used by accessors
include(joinpath("base", "utils", "chemical_formulas.jl"))
include(joinpath("base", "utils", "gene_associations.jl"))

COBREXA.@_export_names()
end

"""
module InputOutput

Input/output functions, as well as pretty printing.
"""
module InputOutput # can't use IO
import ..COBREXA
using ..COBREXA: _constants
using ..Types
using ..Misc
using ..Misc: _maybemap, _default
using ..Accessors
using ..Accessors: _unparse_grr

using ..COBREXA.JSON,
    ..COBREXA.MAT,
    ..COBREXA.SBML,
    ..COBREXA.HDF5,
    ..COBREXA.DocStringExtensions,
    ..COBREXA.SparseArrays,
    ..COBREXA.OrderedCollections

# IO functions
include(joinpath("io", "json.jl"))
include(joinpath("io", "mat.jl"))
include(joinpath("io", "sbml.jl"))
include(joinpath("io", "h5.jl"))
include(joinpath("io", "io.jl"))

# pretty printing 
include(joinpath("io", "show", "pretty_printing.jl"))
include(joinpath("io", "show", "FluxSummary.jl"))
include(joinpath("io", "show", "FluxVariabilitySummary.jl"))
include(joinpath("io", "show", "Gene.jl"))
include(joinpath("io", "show", "MetabolicModel.jl"))
include(joinpath("io", "show", "Metabolite.jl"))
include(joinpath("io", "show", "Reaction.jl"))
include(joinpath("io", "show", "Serialized.jl"))

COBREXA.@_export_names()
end

"""
module Utils

Utility functions.
"""
module Utils
import ..COBREXA
using COBREXA: _constants
using ..Types
using ..Misc
using ..Misc: @_is_reaction_fn
using ..Accessors
using ..COBREXA.SBML,
    ..COBREXA.OrderedCollections,
    ..COBREXA.Serialization,
    ..COBREXA.DocStringExtensions,
    ..COBREXA.SparseArrays

include(joinpath("base", "utils", "Annotation.jl"))
include(joinpath("base", "utils", "bounds.jl"))
include(joinpath("base", "utils", "CoreModel.jl"))
include(joinpath("base", "utils", "enzymes.jl"))
include(joinpath("base", "utils", "fluxes.jl"))
include(joinpath("base", "utils", "gecko.jl"))
include(joinpath("base", "utils", "looks_like.jl"))
include(joinpath("base", "utils", "Reaction.jl"))
include(joinpath("base", "utils", "Serialized.jl"))
include(joinpath("base", "utils", "smoment.jl"))
include(joinpath("base", "utils", "StandardModel.jl"))
include(joinpath("base", "utils", "summary.jl"))

COBREXA.@_export_names()
end

"""
module Analysis

Analysis functions. Contains submodules:
- `Modifications`, which contains optimizer based modifications,
- `Sampling`, which contains samplers,
- `Parallel`, which contains `screen` like functions.
"""
module Analysis
import ..COBREXA
using ....COBREXA: _constants
using ..Misc
using ..Types
using ..Accessors

using ..COBREXA.DocStringExtensions,
    ..COBREXA.JuMP, ..COBREXA.Distributed, ..COBREXA.DistributedData

include(joinpath("base", "solver.jl"))

"""
module Parallel

A module containing purpose built parallelization functions for cobrexa. See
[`screen`](@ref) as an example.
"""
module Parallel
import ....COBREXA
using ....COBREXA: _constants
using ....Misc
using ....Types
using ....Accessors

using ....COBREXA.DocStringExtensions,
    ....COBREXA.JuMP, ....COBREXA.Distributed, ....COBREXA.DistributedData

include(joinpath("analysis", "screening.jl"))

COBREXA.@_export_names()
end

import .Parallel # so that screen functions can be made visible 
include(joinpath("analysis", "flux_balance_analysis.jl"))
include(joinpath("analysis", "flux_variability_analysis.jl"))
include(joinpath("analysis", "minimize_metabolic_adjustment.jl"))
include(joinpath("analysis", "parsimonious_flux_balance_analysis.jl"))
include(joinpath("analysis", "max_min_driving_force.jl"))
include(joinpath("analysis", "gecko.jl"))
include(joinpath("analysis", "smoment.jl"))

"""
module Sampling

A module containing flux sampling functions.
"""
module Sampling
import ....COBREXA
using ....Misc
using ....Types
using ....Accessors
using ..Analysis

using ....COBREXA.DocStringExtensions,
    ....COBREXA.JuMP, ....COBREXA.Distributed, ....COBREXA.DistributedData

include(joinpath("analysis", "sampling", "warmup_variability.jl"))
include(joinpath("analysis", "sampling", "affine_hit_and_run.jl"))

COBREXA.@_export_names()
end

"""
module Modifications

A module containing optimizer based modifications.
"""
module Modifications # optimization modifications
import ....COBREXA
using ....COBREXA: _constants
using ..Analysis
using ....Utils
using ....Types
using ....Misc
using ....Accessors
using ....COBREXA.DocStringExtensions, ....COBREXA.JuMP, ....COBREXA.SparseArrays, ....COBREXA.LinearAlgebra

include(joinpath("analysis", "modifications", "generic.jl"))
include(joinpath("analysis", "modifications", "crowding.jl"))
include(joinpath("analysis", "modifications", "knockout.jl"))
include(joinpath("analysis", "modifications", "loopless.jl"))
include(joinpath("analysis", "modifications", "moment.jl")) # TODO remove and deprecate
include(joinpath("analysis", "modifications", "optimizer.jl"))

COBREXA.@_export_names()
end

COBREXA.@_export_names()
end

"""
module Reconstruction

A module containing functions used to build and modify models. 
"""
module Reconstruction
import ..COBREXA
using ..Types
using ..Misc

using ..COBREXA.DocStringExtensions, ..COBREXA.JuMP

include(joinpath("base", "macros", "change_bounds.jl"))
include(joinpath("base", "macros", "remove_item.jl"))
include(joinpath("base", "macros", "serialized.jl"))

include(joinpath("reconstruction", "CoreModel.jl"))
include(joinpath("reconstruction", "CoreModelCoupled.jl"))
include(joinpath("reconstruction", "StandardModel.jl"))
include(joinpath("reconstruction", "SerializedModel.jl"))

include(joinpath("reconstruction", "Reaction.jl"))
include(joinpath("reconstruction", "enzymes.jl"))

include(joinpath("reconstruction", "community.jl"))

include(joinpath("reconstruction", "gapfill_minimum_reactions.jl"))

include(joinpath("reconstruction", "modifications", "generic.jl"))

COBREXA.@_export_names()
end

end # module
