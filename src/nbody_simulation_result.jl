# SimulationResult sould provide an interface for working with properties of a separate particle
# and with physical properties of the whole system.
struct SimulationResult{sType <: NBodySystem}
    solution::AbstractTimeseriesSolution
    simulation::NBodySimulation{sType}
end

function Base.show(stream::IO, sr::SimulationResult)
    print(stream, "N: ") 
    show(stream, length(sr.simulation.system.bodies))
    println(stream)
    show(stream, sr.simulation)
    print(stream, "Time steps: ") 
    show(stream, length(sr.solution.t))
    println(stream)
    print(stream, "t: ", minimum(sr.solution.t), ", ", maximum(sr.solution.t)) 
    println(stream)
end

(sr::SimulationResult)(args...; kwargs...) = return sr.solution(args...; kwargs...)

function get_velocity(sr::SimulationResult, time::Real, i::Integer=0)
    if typeof(sr.solution[1]) <: RecursiveArrayTools.ArrayPartition
        velocities = sr(time).x[1]
        n = size(velocities, 2)
        if i <= 0
            return velocities[:, 1:end]
        else
            return velocities[:, i]
        end
    else
        velocities = sr(time)
        n = div(size(velocities, 2), 2)
        if i <= 0
            return velocities[:, n + 1:end]
        else
            return velocities[:, n + i]
        end
    end
end

function get_position(sr::SimulationResult, time::Real, i::Integer=0)
    if typeof(sr.solution[1]) <: RecursiveArrayTools.ArrayPartition
        positions = sr(time).x[2]
        n = size(positions, 2)
    else
        positions = sr(time)
        n = div(size(positions, 2), 2)
    end

    if i <= 0
        return positions[:, 1:n]
    else
        return positions[:, i]
    end
end

function get_masses(system::NBodySystem)
    n = length(system.bodies)
    masses = zeros(n)
    for i = 1:n
        masses[i] = system.bodies[i].m
    end
    return masses
end

function temperature(result::SimulationResult, time::Real)
    kb = 1.38e-23
    velocities = get_velocity(result, time)
    masses = get_masses(result.simulation.system)
    temperature = mean(sum(velocities.^2, 1) .* masses) / (3kb)
    return temperature
end

function kinetic_energy(velocities, simulation::NBodySimulation)
    masses = get_masses(simulation.system)
    ke = sum(dot(vec(sum(velocities.^2, 1)), masses / 2))
    return ke
end

function kinetic_energy(sr::SimulationResult, time::Real)
    vs = get_velocity(sr, time)
    return kinetic_energy(vs, sr.simulation)
end

function potential_energy(coordinates, simulation::NBodySimulation)
    e_potential = 0
    system = simulation.system
    n = length(system.bodies)
    if :lennard_jones ∈ keys(system.potentials)
        p = system.potentials[:lennard_jones]
        e_lj = 0
        for i = 1:n
            ri = @SVector [coordinates[1, i], coordinates[2, i], coordinates[3, i]]
            for j = i + 1:n                
                rj = @SVector [coordinates[1, j], coordinates[2, j], coordinates[3, j]]
                
                rij = apply_boundary_conditions!(ri, rj, simulation.boundary_conditions, p)
                
                if rij[1] < Inf
                    rij_2 = dot(rij, rij)
                    σ_rij_6 = (p.σ2 / rij_2)^3
                    σ_rij_12 = σ_rij_6^2
                    e_lj += (σ_rij_12 - σ_rij_6 )
                end
            end
        end 
        e_potential += 4 * p.ϵ * e_lj
    end
    e_potential
end

function potential_energy(sr::SimulationResult, time::Real)
    e_potential = 0
    coordinates = get_position(sr, time)
    return potential_energy(coordinates, sr.simulation)
end

function total_energy(sr::SimulationResult, time::Real)
    e_kin = kinetic_energy(sr, time)
    e_pot = potential_energy(sr, time)
    e_kin + e_pot
end

function initial_energy(simulation::NBodySimulation)
    (u0, v0, n) = gather_bodies_initial_coordinates(simulation.system)
    return potential_energy(u0, simulation) + kinetic_energy(v0, simulation) 
end

# Instead of treating NBodySimulation as a DiffEq problem and passing it into a solve method
# it is better to use a specific function for n-body simulations.
function run_simulation(s::NBodySimulation, alg_type=Tsit5(), args...; kwargs...)
    initial_en = initial_energy(s)
    function energy_manifold!(residual, u)
        n = length(s.system.bodies)
        vs = @view u[:, n+1:end]
        us = @view u[:,1:n]
        residual[:,n+1:end] = initial_en - kinetic_energy(vs, s) - potential_energy(us, s)
    end
    energy_cb = ManifoldProjection(energy_manifold!)
    solution = solve(ODEProblem(s), alg_type, args...; kwargs...)
    return SimulationResult(solution, s)
end

# this should be a method for integrators designed for the SecondOrderODEProblem (It is worth somehow to sort them from other algorithms)
function run_simulation(s::NBodySimulation, alg_type::Union{VelocityVerlet,DPRKN6,Yoshida6}, args...; kwargs...)
    solution = solve(SecondOrderODEProblem(s), alg_type, args...; kwargs...)
    return SimulationResult(solution, s)
end

@recipe function generate_data_for_scatter(sr::SimulationResult{<:PotentialNBodySystem}, time::Real=0.0)
    solution = sr.solution
    n = length(sr.simulation.system.bodies)

    if :gravitational ∈ keys(sr.simulation.system.potentials)
    
        xlim --> 1.1 * [minimum(solution[1,1:n,:]), maximum(solution[1,1:n,:])]
        ylim --> 1.1 * [minimum(solution[2,1:n,:]), maximum(solution[2,1:n,:])]        
    
        for i in 1:n
            @series begin
                label --> "Orbit $i"
                vars --> (3 * (i - 1) + 1, 3 * (i - 1) + 2)
                solution
            end
        end
    else
        borders = sr.simulation.boundary_conditions
    
        positions = get_position(sr, time)
        
        xlim --> 1.1 * [minimum(solution[1,1:n,:]), maximum(solution[1,1:n,:])]
        ylim --> 1.1 * [minimum(solution[2,1:n,:]), maximum(solution[2,1:n,:])]  
        #zlim --> 1.1 * [minimum(solution[3,1:n,:]), maximum(solution[3,1:n,:])]  
    
        seriestype --> :scatter
        markersize --> 5

        positions = get_position(sr, time)
        (positions[1,:], positions[2,:], positions[3,:])
        #(positions[1,:], positions[2,:])
    end
end

# This iterator interface is implemented specifically for making animation.
# Probably, there will be a wrapper for this in the future.
Base.start(::SimulationResult) = 1

Base.done(sr::SimulationResult, state) = state > length(sr.solution.t)

function Base.next(sr::SimulationResult, state) 
    positions = get_position(sr, sr.solution.t[state])

    if sr.simulation.boundary_conditions isa PeriodicBoundaryConditions
        L = sr.simulation.boundary_conditions[2]
        map!(x ->  x -= L * floor(x / L), positions, positions)
    end

    (positions[1,:], positions[2,:], positions[3,:]), state + 1
    #(positions[1,:], positions[2,:]), state + 1
end