#
# Copyright (c) 2023 Julian Trommer
# Licensed under the MIT license. See LICENSE file in the project root for details.
#

using ComponentArrays

import DataFrames: DataFrame
import JLD2: load, save
import Statistics: mean
import Zygote: pullback

include("feature_graph.jl")
include("graph_net_blocks.jl")

"""
    GraphNetwork(model, ps, st, e_norm, n_norm, o_norm)

The central data structure that contains the neural network and the normalisers corresponding to the components of the GNN (edge features, node features and output).

# Arguments
- `model`: The Enocde-Process-Decode model as a [Lux.Chain](@ref).
- `ps`: Parameters of the model.
- `st`: State of the model.
- `e_norm`: Normaliser for the edge features of the GNN.
- `n_norm`: Normaliser for the node features of the GNN, whereas each feature has its own normaliser.
- `o_norm`: Normaliser for the output of the GNN.

"""
mutable struct GraphNetwork
    model
    ps
    st
    e_norm::NormaliserOnline
    n_norm::Dict{String, Union{NormaliserOffline, NormaliserOnline}}
    o_norm::NormaliserOnline
end

function build_mlp(input_size::T, latent_size::T, output_size::T, hidden_layers::T; layer_norm=true, dev=cpu) where T <: Integer
    if layer_norm
        return Chain(
            Dense(input_size, latent_size, relu),
            [Dense(latent_size, latent_size, relu) for _ in 1:hidden_layers]...,
            Dense(latent_size, output_size),
            LayerNorm((output_size,))
        )
    else
        return Chain(
            Dense(input_size, latent_size, relu),
            [Dense(latent_size, latent_size, relu) for _ in 1:hidden_layers]...,
            Dense(latent_size, output_size)
        )
    end
end


"""
    build_model(quantities_size::Integer, dims, output_size::Integer, mps::Integer, layer_size::Integer, hidden_layers::Integer, device::Function)

Constructs the Encode-Process-Decode model as a [Lux.Chain](@ref) with the given arguments.

# Arguments
- `quantities_size`: Sum of dimensions of each node feature.
- `dims`: Dimension of the mesh.
- `output_size`: Sum of dimensions of output quantities.
- `mps`: Number of message passing steps.
- `layer_size`: Size of hidden layers.
- `hidden_layers`: Number of hidden layers.
- `device`: Device where the model should be loaded (see [Lux.gpu_device()](@ref) and [Lux.cpu_device()](@ref)).

# Returns
- `model`: The Encode-Process-Decode model as a [Lux.Chain](@ref).
"""
function build_model(quantities_size::Integer, dims, output_size::Integer, mps::Integer, layer_size::Integer, hidden_layers::Integer, device::Function)
    encoder = Encoder(build_mlp(quantities_size, layer_size, layer_size, hidden_layers, dev=device), build_mlp(dims + 1, layer_size, layer_size, hidden_layers, dev=device))

    processors = Vector{Processor}()
    for _ in 1:mps
        push!(processors, Processor(build_mlp(2 * layer_size, layer_size, layer_size, hidden_layers, dev=device), build_mlp(3 * layer_size, layer_size, layer_size, hidden_layers, dev=device)))
    end

    decoder = Decoder(build_mlp(layer_size, layer_size, output_size, hidden_layers; layer_norm=false, dev=device))


    model = Chain(encoder, processors..., decoder)

    return model
end

function loss(ps, gn, graph::FeatureGraph, target::AbstractArray{Float32, 2}, mask::AbstractArray{T, 1}, loss_function) where T <: Integer
    output, st = gn.model(graph, ps, gn.st)
    gn.st = st
    
    error = loss_function(target, output)

    loss = mean(error[mask])

    return loss
end

"""
    step!(gn, graph, target_quantities_change, mask, loss_function)


# Arguments
- `gn`: The used [GraphNetCore.GraphNetwork](@ref).
- `graph`: Input data stored in a [GraphNetCore.FeatureGraph](@ref).
- `target_quantities_change`: Derivatives of quantities of interest (e.g. via finite differences from data).
- `mask`: Mask for excluding node types that should not be updated.
- `loss_function`: Loss function that is used to calculate the error.

# Returns
- `gs`: The calculated gradients.
- `train_loss`: The calculated training loss.
"""
function step!(gn, graph, target_quantities_change, mask, loss_function)
    train_loss, back = pullback(ps -> loss(ps, gn, graph, target_quantities_change, mask, loss_function), gn.ps) 
    
    gs = back(one(train_loss))
    
    return gs, train_loss
end

"""
    save!(gn, opt_state, df_train::DataFrame, df_valid::DataFrame, step::Integer, train_loss::Float32, path::String; is_training = true)

Creates a checkpoint of the [GraphNetCore.GraphNetwork](@ref) at the given training step.

# Arguments
- `gn`: The [GraphNetCore.GraphNetwork](@ref) that a checkpoint is created of.
- `opt_state`: State of the optimiser.
- `df_train`: [DataFrames.DataFram](@ref) that stores the train losses at the checkpoints.
- `df_valid`: [DataFrames.DataFram](@ref) that stores the validation losses at the checkpoints (only improvements are saved).
- `step`: Current training step where the checkpoint is created.
- `train_loss`: Current training loss.
- `path`: Path to the folder where checkpoints are saved.

# Keyword Arguments
- `is_training = true`: True if used in training, false otherwise (in validation).
"""
function save!(gn, opt_state, df_train::DataFrame, df_valid::DataFrame, step::Integer, train_loss::Float32, path::String; is_training = true)
    if is_training
        push!(df_train, [step, train_loss])
    else
        push!(df_valid, [step, train_loss])
    end

    save(joinpath(path, "checkpoint_$step.jld2"), Dict(
            "ps_data" => cpu_device()(getdata(gn.ps)),
            "ps_axes" => getaxes(gn.ps),
            "st" => cpu_device()(gn.st),
            "e_norm" => serialize(gn.e_norm),
            "n_norm" => serialize(gn.n_norm),
            "o_norm" => serialize(gn.o_norm),
            "opt_state" => cpu_device()(opt_state),
            "df_train" => df_train,
            "df_valid" => df_valid
        )
    )

    if isfile(joinpath(path, "checkpoints"))
        cps = readlines(joinpath(path, "checkpoints"))
    else
        cps = Vector{String}()
    end
    push!(cps, string(step))
    if length(cps) > 5
        rm(joinpath(path, "checkpoint_$(cps[1]).jld2"))
        deleteat!(cps, 1)
    end
    open(joinpath(path, "checkpoints"), "w") do f
        for cp in cps
            write(f, cp * "\n")
        end
    end
end

"""
    load(quantities, dims, norms, output, message_steps, ls, hl, opt, device::Function, path::String)

Loads the [GraphNetCore.GraphNetwork](@ref) from the latest checkpoint at the given path. 

# Arguments
- `quantities`: Sum of dimensions of each node feature.
- `dims`: Dimension of the mesh.
- `norms`: Normalisers for node features.
- `output`: Sum of dimensions of output quantities.
- `message_steps`: Number of message passing steps.
- `ls`: Size of hidden layers.
- `hl`: Number of hidden layers.
- `opt`: Optimiser that is used for training. Set this to `nothing` if you want to use the optimiser from the checkpoint.
- `device`: Device where the model should be loaded (see [Lux.gpu_device()](@ref) and [Lux.cpu_device()](@ref)).
- `path`: Path to the folder where the checkpoint is.

# Returns
- `gn`: The loaded [GraphNetCore.GraphNetwork](@ref) from the checkpoint.
- `opt_state`: The loaded optimiser state. Is nothing if no checkpoint was found or an optimiser was passed as an argument.
- `df_train`: [DataFrames.DataFram](@ref) containing the train losses at the checkpoints.
- `df_valid`: [DataFrames.DataFram](@ref) containing the validation losses at the checkpoints (only improvements are saved).
"""
function load(quantities, dims, norms, output, message_steps, ls, hl, opt, device::Function, path::String)
    if isfile(joinpath(path, "checkpoints"))
        step = parse(Int, readlines(joinpath(path, "checkpoints"))[end])
        ps_data, ps_axes, st, e_norm, n_norm, o_norm, opt_state, df_train, df_valid = load(joinpath(path, "checkpoint_$step.jld2"), "ps_data", "ps_axes", "st", "e_norm", "n_norm", "o_norm", "opt_state", "df_train", "df_valid")

        ps = ComponentArray(ps_data, ps_axes) |> device
        st = st |> device
        
        en = NormaliserOnline(e_norm, device)
        for (k, n) in n_norm
            norms[k] = NormaliserOnline(n, device)
        end
        on = NormaliserOnline(o_norm, device)

        model = build_model(quantities, dims, output, message_steps, ls, hl, device)
        gn = GraphNetwork(model, ps, st, en, norms, on)
        
        if !isnothing(opt)
            return gn, nothing, df_train, df_valid
        else
            return gn, device(opt_state), df_train, df_valid
        end
    else
        model = build_model(quantities, dims, output, message_steps, ls, hl, device)
        ps, st = Lux.setup(Random.default_rng(), model)

        ps = ComponentArray(ps) |> device
        st = st |> device

        gn = GraphNetwork(model, ps, st, NormaliserOnline(dims + 1, device), norms, NormaliserOnline(output, device))
        
        return gn, nothing, DataFrame(step=Integer[], loss=Float32[]), DataFrame(step=Integer[], loss=Float32[])
    end
    
end
