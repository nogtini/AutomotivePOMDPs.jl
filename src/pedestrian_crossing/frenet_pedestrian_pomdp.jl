
@with_kw mutable struct FrenetPedestrianPOMDP{B <: Updater} <: DriverModel{LatLonAccel}
    a::LatLonAccel = LatLonAccel(0.0, 0)
    env::CrosswalkEnv = CrosswalkEnv(CrosswalkParams())
    sensor::AutomotiveSensors.GaussianSensor = AutomotiveSensors.GaussianSensor(AutomotiveSensors.LinearNoise(10, 0., 0.), 
                                                               AutomotiveSensors.LinearNoise(10, 0., 0.), 0, 0, MersenneTwister(1)) 
    timestep::Float64 = 0
    t_current::Float64 = 0
    tick::Int64 = 0
   
    obstacles::Vector{ConvexPolygon}

    risk::Float64 = 0.0
    sensor_observations::Vector{Vehicle} = []


    update_tick_high_level_planner::Int64 = 1

    pomdp::SingleOCFPOMDP = SingleOCFPOMDP()
    policy::AlphaVectorPolicy{SingleOCFPOMDP,SingleOCFAction} = AlphaVectorPolicy(pomdp, Vector{Vector{Float64}}())
    updater::B = SingleOCFUpdater(pomdp)
    b::SingleOCFBelief = SingleOCFBelief(Vector{SingleOCFState}(), Vector{Float64}())

    ego_vehicle::Vehicle = Vehicle(VehicleState(VecSE2(0., 0., 0.), 0.), VehicleDef(), 1)

    desired_velocity::Float64 = 40.0 / 3.6
end



function AutomotiveDrivingModels.observe!(model::FrenetPedestrianPOMDP, scene::Scene, roadway::Roadway, egoid::Int)

    ego = scene[findfirst(scene, egoid)]
    pomdp.ego_vehicle = ego
    model.ego_vehicle = ego
    model.sensor_observations = measure(model.sensor, ego, scene, roadway, model.obstacles)
    
    ################ High Level Planner ###################################################
    if (  true ) #model.tick % model.update_tick_high_level_planner == 0 )

        println("--------------------------POMDP high level planner----------------------- t: ", model.t_current)
        println("EGO: x/y:", ego.state.posG.x, " / ",  ego.state.posG.y, " v: ", ego.state.v)

        ego_t = ego.state.posF.t
        ego_s = ego.state.posF.s
        ego_v = ego.state.v
        obs = get_state_absent(pomdp,ego.state.posG.y, ego_v) 

        delta_s = -10.
        delta_t = -10.
        for object in model.sensor_observations
            println("PED: x/y: ", object.state.posG.x, " / ", object.state.posG.y, " v: ", object.state.v)
            
            object_posF = Frenet(proj(object.state.posG, get_lane(env.roadway, ego.state), env.roadway, move_along_curves=false),env.roadway)
            
            delta_s = object_posF.s - ego_s
            delta_t = object_posF.t - ego_t
            delta_theta = object_posF.ϕ - ego.state.posF.ϕ
            ped_v = object.state.v
            
            obs = SingleOCFState(ego_t, ego_v, delta_s, delta_t, delta_theta, ped_v)
            println("delta_s: ", delta_s, " delta_t: ", delta_t)
            println("Observation cont: ", obs)

        end
        
      
        # init belief for the first time step
        if (model.t_current == 0 )
            # no object or out of state space
            if ( length(model.sensor_observations) == 0 || is_observation_absent(pomdp, obs) )
                model.b = initBeliefAbsentPedestrian(pomdp, ego_t, ego_v)
                println("init belief absent")
            else
                model.b = initBeliefPedestrian(pomdp, obs)
                println("init belief observation")

            end
        end


        action_pomdp = SingleOCFAction(model.a.a_lon, model.a.a_lat)
        println("action before update: ", action_pomdp)

        b_ = update(model.updater, model.b, action_pomdp, obs)  
        model.b = deepcopy(b_)

#=
            b_states = []
            b_prob = []
            for (s, prob) in weighted_iterator(b_)
                if ( prob > 1e-4)
                    push!(b_states, s)
                    push!(b_prob, prob)
                end
            end
            model.b = SingleOCFBelief(b_states, b_prob) 

       =#

         #   println(model.b)
        println("b-length: ", length(model.b))
            
            act = action(model.policy, model.b) # policy
            model.a = LatLonAccel(act.lateral_movement, act.acc)
            println("action after update: ", act)

        if (model.tick > 2 )
        #    model.a = LatLonAccel(0.0, -4.0)
        #    println("manual intervention")
        #    println(model.b)
        end


    end
    
    model.risk = length(model.b)
    model.tick += 1
    model.t_current = model.t_current + model.timestep 

end


# TODO: implementation in Frenet Frame
function AutomotiveDrivingModels.propagate(veh::Vehicle, action::LatLonAccel, roadway::Roadway, Δt::Float64)

    # new velocity
    v_ = veh.state.v + action.a_lon*Δt
    v_ = clamp(v_, 0, v_)

    # lateral offset
    delta_y = action.a_lat * Δt   # a_lat corresponds to lateral velocity --> a_lat == v_lat
    if v_ <= 0.
        delta_y = 0.
    end
    s_new = v_ * Δt

    # longitudional distance based on required velocity and lateral offset
#    delta_x = sqrt(s_new^2 - delta_y^2 )
    y_ = veh.state.posG.y + delta_y

    if v_ > 0
        x_ = veh.state.posG.x + veh.state.v*Δt + action.a_lon*Δt^2/2# + delta_x
    else
        x_ = veh.state.posG.x + veh.state.v*Δt# + delta_x
    end

    return VehicleState(VecSE2(x_, y_, veh.state.posG.θ), roadway, v_)
end

function AutomotiveDrivingModels.get_name(model::FrenetPedestrianPOMDP)
    return "Frenet Pedestrian POMDP"
end

AutomotiveDrivingModels.rand(model::FrenetPedestrianPOMDP) = model.a




@with_kw mutable struct ObservationCallback
    risk::Vector{Float64}
    sensor_observations::Vector{Vector{Vehicle}}
    belief::Vector{SingleOCFBelief}
    ego_vehicle::Vector{Vehicle}
    action::Vector{SingleOCFAction}
end

function AutomotiveDrivingModels.run_callback{S,D,I,R,M<:DriverModel}(
        callback::ObservationCallback,
        rec::EntityQueueRecord{S,D,I},
        roadway::R,
        models::Dict{I,M},
        tick::Int)
    
    push!(callback.risk, models[1].risk)
    push!(callback.sensor_observations, models[1].sensor_observations)
    push!(callback.belief, models[1].b)
    push!(callback.ego_vehicle, models[1].ego_vehicle)
    act = SingleOCFAction(models[1].a.a_lon, models[1].a.a_lat)
    push!(callback.action, act)

    return is_crash(rec[0])
end


"""
    is_crash(scene::Scene)
return true if the ego car is in collision in the given scene, do not check for collisions between
other participants
"""
function is_crash(scene::Scene)
    ego = scene[findfirst(scene, 1)]
    @assert ego.id == 1
    if ego.state.v ≈ 0
        return false
    end
    for veh in scene
        if veh.id != 1
            if AutomotivePOMDPs.is_colliding(ego, veh)
                println("-----------------> Collision <----------------------")
                return true
            end
        end
    end
    return false
end




