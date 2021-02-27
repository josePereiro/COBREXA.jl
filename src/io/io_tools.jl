"""
    read_model(file_location::String))

Reads a model at `file_location` and returns a constraint based `model::CobraTools.Model`.
Currently supported formats include SBML (.xml), Matlab (.mat) and JSON (.json) models.
The model format is inferred from the `file_location` extension.

Note, some meta-information may be lost when importing a model. Importantly, only information regarding the
reactions, metabolites and genes are imported. Currently reading JSON models captures the most meta-information
regarding reactions, metabolites and genes (e.g. the notes and annotation fields). 

When importing Matlab models some annotation and notes may not be imported because of non-standard field names used by some models.
Gene reaction rules are successfully imported only if they adhere to this format: `"(YIL010W and YLR043C) or (YIL010W and YGR209C)"`, 
where `or` can be interchanged with `OR, |, ||` and `and` can be interchanged with `AND, &, &&`.
Other gene reaction rules formats are not supported yet, but file an issue if your format is standard and needs to be included. 

However, in all cases the basic information needed to perform constraint based analysis should be imported successfully, 
e.g. stoichiometrix matrix, constraints etc..
Advanced tools that require, e.g. metabolite formulas, gene reaction rules, and KEGG or BIGG IDs, will not function if these are improperly imported.
Always inspect the imported model before running analysis (garbage in -> garbage out). 
"""
function read_model(file_location::String)
    if endswith(file_location, ".json")
        try 
            model = reconstruct_model_json(file_location)
        catch err
            @error "JSON model reading error.\n$err"
            model = CobraTools.Model()
        end
    elseif endswith(file_location, ".xml")
        try
            model = reconstruct_model_sbml(file_location)
        catch err
            @error "SBML model reading error.\n$err"
            model = CobraTools.Model()
        end
    elseif endswith(file_location, ".mat")
       try
            model = reconstruct_model_matlab(file_location)
       catch err
            @error "Matlab model reading error.\n$err"
            model = CobraTools.Model()
       end
    else
        @error "Model format not supported. The format is inferred from the file extension. Supported formats: *.mat, *.xml, *.json."
        model = CobraTools.Model()
    end
    return model
end

"""
    parsegrr(string_rule, genes::Array{Gene, 1})

Parse a gene reaction rule string `string_rule` into a nested `gene` array `Array{Array{Gene, 1}, 1}`. 

Format: (YIL010W and YLR043C) or (YIL010W and YGR209C) where `or` can also be `OR, |, ||` and where `and` can also be `AND, &, &&`.
"""
function parse_grr(s::String, genes::Array{Gene, 1})
    if s == "" || isnothing(s)
        return Array{Array{Gene, 1}, 1}()
    end
    # first get the gene id list in string format
    gene_string_rules = Array{Array{String, 1}, 1}()
    or_genes = split(s, r"\s?(or|OR|(\|\|)|\|)\s?") # separate or terms
    for or_gene in or_genes
        and_genes = split(replace(or_gene, r"\(|\)" => ""), r"\s?(and|AND|(\&\&)|\&)\s?")
        push!(gene_string_rules, and_genes)
    end
    # now map these gene string ids to genes
    grr = Array{Array{Gene, 1}, 1}()
    for gsr in gene_string_rules
        gene_list = Array{Gene, 1}()
        for g in gsr
            gene = findfirst(genes, g)
            isnothing(gene) && (@warn "Gene not found..."; continue)
            push!(gene_list, gene)
        end
        push!(grr, gene_list)
    end
    return grr
end

"""
    unparse_grr(grr::Array{Array{Gene, 1}, 1}

Converts a nested `gene` array, `grr`, back into a grr string.
"""
function unparse_grr(grr::Array{Array{Gene, 1}, 1})
    grr_strings = String[]
    for gr in grr
        push!(grr_strings, "("*join([g.id for g in gr], " and ")*")")
    end
    grr_string = join(grr_strings, " or ")
    return grr_string
end

"""
    reconstructmodeljson(modeldict::String)
"""
function reconstruct_model_json(file_location::String)
    modeldict = JSON.parsefile(file_location)
    
    modelid = modeldict["id"]

    mets = Metabolite[]
    for met in modeldict["metabolites"]
        id = ""
        name = ""
        formula = ""
        charge = 0
        compartment = ""
        notes = Dict{String, Array{String, 1}}()
        annotation = Dict{String, Union{Array{String, 1}, String}}()
        for (k, v) in met
            if k == "id"
                id = v
            elseif k == "name"
                name = v
            elseif k == "formula"
                formula = v
            elseif k == "charge"
                charge = v
            elseif k == "compartment"
                compartment = v
            elseif k == "notes"
                notes = Dict{String, Array{String, 1}}(kk=>vv for (kk, vv) in v)
            elseif k == "annotation"
                for (kk, vv) in v
                    if typeof(vv) == String
                        annotation[kk] = vv
                    else
                        annotation[kk] = convert(Array{String, 1}, vv)
                    end
                end
            else
                @warn "Unrecognized reaction field: $k"
            end
        end
        push!(mets, Metabolite(id, name, formula, charge, compartment, notes, annotation))
    end

    genes = Gene[]
    for gene in modeldict["genes"]
        id = ""
        name = ""
        notes = Dict{String, Array{String, 1}}()
        annotation = Dict{String, Union{Array{String, 1}, String}}()
        for (k, v) in gene
            if k == "id"
                id = v
            elseif k == "name"
                name = v
            elseif k == "notes"
                notes = Dict{String, Array{String, 1}}(kk=>vv for (kk, vv) in v)
            elseif k == "annotation"
                for (kk, vv) in v
                    if typeof(vv) == String
                        annotation[kk] = vv
                    else
                        annotation[kk] = convert(Array{String, 1}, vv)
                    end
                end
            else
                @warn "Unrecognized reaction field: $k"
            end
        end
        push!(genes, Gene(id, name, notes, annotation))
    end

    rxns = Reaction[]
    for rxn in modeldict["reactions"]
        id = ""
        name = ""
        metabolites = Dict{Metabolite, Float64}()
        lb = -1000.0 
        ub = 1000.0 
        grr = Array{Array{Gene, 1}, 1}()
        subsystem = "" 
        notes = Dict{String, Array{String, 1}}() 
        annotation = Dict{String, Union{Array{String, 1}, String}}()
        objective_coefficient = 0.0
        for (k, v) in rxn
            if k == "id"
                id = v
            elseif k == "name"
                name = v
            elseif k == "metabolites"
                metabolites = Dict{Metabolite, Float64}() 
                for (kk, vv) in v
                    ind = findfirst(x->x.id == kk, mets)
                    isnothing(ind) ? (@warn "Metabolite $kk not found in reaction assignment."; continue) : nothing
                    metabolites[mets[ind]] = vv
                end 
            elseif k == "lower_bound"
                lb = v
            elseif k == "upper_bound"
                ub = v
            elseif k == "gene_reaction_rule"
                grr = parse_grr(v, genes)
            elseif k == "subsystem"
                subsystem = v
            elseif k == "notes"
                notes = Dict{String, Array{String, 1}}(kk=>vv for (kk, vv) in v)
            elseif k == "annotation"
                for (kk, vv) in v
                    if typeof(vv) == String
                        annotation[kk] = vv
                    else
                        annotation[kk] = convert(Array{String, 1}, vv)
                    end
                end
            elseif k == "objective_coefficient"
                objective_coefficient = v
            else
                @warn "Unrecognized reaction field: $k"
            end
        end
        push!(rxns, Reaction(id, name, metabolites, lb, ub, grr, subsystem, notes, annotation, objective_coefficient))
    end
    
    return CobraTools.Model(modelid, rxns, mets, genes)
end

"""
    reconstruct_model_matlab(file_location::String)
"""
function reconstruct_model_matlab(file_location::String)
    matfile = matread(file_location)
    model_name = collect(keys(matfile))[1]
    modeldict = matfile[model_name]

    # the model_id can be written in many places, try varying levels of specificity
    model_id = haskey(modeldict, "description") ? modeldict["description"] : model_name
    model_id = haskey(modeldict, "modelName") ? modeldict["modelName"] : model_name # more specific
    
    mets = Metabolite[]
    for i in eachindex(modeldict["mets"])
        id = haskey(modeldict, "mets") ? modeldict["mets"][i] : ""
        if id == ""
            continue
        end

        name = haskey(modeldict, "metNames") ? modeldict["metNames"][i] : ""
        compartment = ""
        formula = ""
        if haskey(modeldict, "metFormulas") 
            formula = string(modeldict["metFormulas"][i])
        elseif haskey(modeldict, "metFormula") 
            formula = string(modeldict["metFormula"][i])    
        end

        charge = 0 # sometimes inconsistently named
        if haskey(modeldict, "metCharge") && !isnan(modeldict["metCharge"][i])
            charge = modeldict["metCharge"][i]
        elseif haskey(modeldict, "metCharges") && !isnan(modeldict["metCharges"][i])
            charge = modeldict["metCharges"][i]
        end
        
        # look for annotation data, assume delimited by "; "
        annotation = Dict{String, Union{Array{String, 1}, String}}()
        anno_kid = Dict("metBiGGID"=>"bigg.metabolite","metKEGGID"=>"kegg.compound","metMetaNetXID"=>"metanetx.chemical", "metChEBIID"=>"chebi")
        for (anno, kid) in anno_kid
            if haskey(modeldict, anno)
                annotation[kid] = string.(split(string(modeldict[anno][i]), "; "))
            end
        end
        if haskey(modeldict, "metSBOTerms")
            annotation["sbo"] = string(modeldict["metSBOTerms"][i])
        end
        
        # look for some notes
        notes = Dict{String, Array{String, 1}}()
        if haskey(modeldict, "metNotes")
            notes["note"] = string.(split(string(modeldict["metNotes"][i]), "; "))
        end            

        push!(mets, Metabolite(id, name, formula, charge, compartment, notes, annotation))
    end

    genes = Gene[]
    for i in eachindex(modeldict["genes"])
        id = haskey(modeldict, "genes") ? modeldict["genes"][i] : ""
        if id == ""
            continue # skip blanks
        end

        # these fields often don't exist in the matlab models, ignore for now
        name = ""
        notes =  Dict{String, Array{String, 1}}()
        annotation = Dict{String, Union{Array{String, 1}, String}}()
        
        push!(genes, Gene(id, name, notes, annotation))
    end

    rxns = Reaction[]
    for i in eachindex(modeldict["rxns"])
        id = haskey(modeldict, "rxns") ? modeldict["rxns"][i] : ""
        if id == ""
            continue # skip blanks
        end

        name = haskey(modeldict, "rxnNames") ? modeldict["rxnNames"][i] : ""
        metinds = findall(x -> x .!= 0.0, modeldict["S"][:, i])
        metabolites = Dict{Metabolite, Float64}(mets[j]=>modeldict["S"][j, i] for j in metinds)

        lb = haskey(modeldict, "lb") ? modeldict["lb"][i] : -1000.0 # reversible by default
        ub = haskey(modeldict, "ub") ? modeldict["ub"][i] : 1000.0 # reversible by default

        grr_string = haskey(modeldict, "grRules") ? modeldict["grRules"][i] : ""
        subsystem = join(modeldict["subSystems"][i], "; ")

        objective_coefficient = haskey(modeldict, "c") ? modeldict["c"][i] : 0.0

        # look for some annotations
        annotation = Dict{String, Union{Array{String, 1}, String}}()
        anno_kids = Dict("rxnKEGGID"=>"kegg.reaction", "rxnECNumbers"=>"ec-code", "rxnBiGGID"=>"bigg.reaction")
        for (anno, kid) in anno_kids
            if haskey(modeldict, anno)
                annotation[kid] = string.(split(string(modeldict[anno][i]), "; "))
            end    
        end
        if haskey(modeldict, "rxnSBOTerms")
            annotation["sbo"] = string(modeldict["rxnSBOTerms"][i])
        end
        
        # look for some notes
        notes = Dict{String, Array{String, 1}}()
        if haskey(modeldict, "rxnNotes")
            notes["note"] = string.(split(string(modeldict["rxnNotes"][i]), "; "))
        end

        # get gene reaction rule
        grr = parse_grr(grr_string, genes)

        push!(rxns, Reaction(id, name, metabolites, lb, ub, grr, subsystem, notes, annotation, objective_coefficient))
    end

    return CobraTools.Model(model_id, rxns, mets, genes)
end

"""
    reconstruct_model_sbml(file_location::String)
"""
function reconstruct_model_sbml(file_location::String)
    # m = readSBML(file_location)
    # m is now a Model structure with:
    # m.reactions
    # m.species
    # m.compartments
        # return Model()
    return CobraTools.Model()
end

"""
    save_model(model::CobraTools.Model, file_location::String)

Save model at `file_location`. Infers format from `file_location` extension.
Supported formats include SBML (.xml), Matlab COBRA models (.mat) and JSON COBRA models (.json).

Note, only the fields contained in model are saved. Make sure that information isn't
lost between reading a model and writing a model (e.g. check gene reaction rules, notes and annotations).
"""
function save_model(model::CobraTools.Model, file_location::String)
    if endswith(file_location, ".json")
        save_json_model(model, file_location)
    elseif endswith(file_location, ".xml")
        @warn "Not implemented!"
    elseif endswith(file_location, ".mat")
        save_matlab_model(model, file_location)
    else
        @error "Model format not supported. The format is inferred from the file extension. Supported formats: *.mat, *.xml, *.json."
    end
end

"""
    save_json_model(model::CobraTools.Model, file_location::String)
"""
function save_json_model(model::CobraTools.Model, file_location::String)
    modeldict = Dict{String, Any}()
    modeldict["id"] = model.id
    
    mets = []
    for m in model.metabolites
        mdict = Dict()
        mdict["id"] = m.id
        mdict["name"] = m.name
        mdict["formula"] = m.formula
        mdict["charge"] = m.charge
        mdict["compartment"] = m.compartment
        mdict["notes"] = m.notes
        mdict["annotation"] = m.annotation
        push!(mets, mdict)
    end
    modeldict["metabolites"] = mets
    
    genes = []
    for g in model.genes
        gdict = Dict()
        gdict["id"] = g.id
        gdict["name"] = g.name
        gdict["notes"] = g.notes
        gdict["annotation"] = g.annotation
        push!(genes, gdict)
    end
    modeldict["genes"] = genes    
    
    rxns = []
    for r in model.reactions
        rdict = Dict()
        rdict["id"] = r.id
        rdict["name"] = r.name
        rdict["metabolites"] = Dict{String, Float64}(k.id=>v for (k, v) in r.metabolites)
        rdict["lower_bound"] = r.lb
        rdict["upper_bound"] = r.ub
        rdict["gene_reaction_rule"] = unparse_grr(r.grr)
        rdict["subsystem"] = r.subsystem
        rdict["notes"] = r.notes
        rdict["annotation"] = r.annotation
        rdict["objective_coefficient"] = r.objective_coefficient
        push!(rxns, rdict)
    end

    modeldict["reactions"] = rxns
    open(file_location, "w") do io
        JSON.print(io, modeldict)
    end
end

"""
    save_matlab_model(model::CobraTools.Model, file_location::String)

Some information is lost here, e.g. notes and some annotations.
"""
function save_matlab_model(model::CobraTools.Model, file_location::String)    
    S, b, ubs, lbs = get_core_model(model)

    mdict = Dict("c" => [r.objective_coefficient for r in model.reactions],
    "modelName" => model.id,
    "mets" => [m.id for m in model.metabolites],
    "subSystems" => [r.subsystem for r in model.reactions],
    "b" => Array(b),
    "metFormulas" => [m.formula for m in model.metabolites],
    "ub" => Array(ubs),
    "rxnNames" => [r.name for r in model.reactions],
    "description" => model.id,
    "genes" => [g.id for g in model.genes],
    "grRules" => [unparse_grr(r.grr) for r in model.reactions],
    "S" => Array(S),
    "metNames" => [m.name for m in model.metabolites],
    "lb" => Array(lbs),
    "metCharge" => [m.charge for m in model.metabolites],
    "rxns" => [r.id for r in model.reactions],
    "rxnKEGGID" => [join(get(r.annotation, "kegg.reaction", [""]), "; ") for r in model.reactions],
    "rxnECNumbers" => [join(get(r.annotation, "ec-code", [""]), "; ") for r in model.reactions],
    "rxnBiGGID" => [join(get(r.annotation ,"bigg.reaction", [""]), "; ") for r in model.reactions],
    "rxnSBOTerms" => [get(r.annotation ,"sbo", "") for r in model.reactions],
    "metBiGGID" => [join(get(m.annotation, "bigg.metabolite", [""]), "; ") for m in model.metabolites],
    "metSBOTerms" => [get(m.annotation, "sbo", "") for m in model.metabolites],
    "metKEGGID" => [join(get(m.annotation, "kegg.compound", [""]), "; ") for m in model.metabolites],
    "metMetaNetXID" => [join(get(m.annotation, "metanetx.chemical", [""]), "; ") for m in model.metabolites],
    "metChEBIID" => [join(get(m.annotation, "chebi", [""]), "; ") for m in model.metabolites])
    
    matwrite(file_location, Dict("model" => mdict)) 
end

"""
    save_sbml_model(model::CobraTools.Model, file_location::String)
"""
function save_sbml_model(model::CobraTools.Model, file_location::String)
    # To do...
end
