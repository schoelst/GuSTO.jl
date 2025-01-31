export DoubleIntR2
export init_traj_straightline, init_traj_geometricplan

mutable struct DoubleIntR2 <: DynamicsModel
  # state: r v p omega
  x_dim
  u_dim
  clearance

  # Parameters that can be updated
  f::Vector
  A
  B
end

function DoubleIntR2()
  x_dim = 4
  u_dim = 2
  clearance = 0.05
  DoubleIntR2(x_dim, u_dim, clearance, [], [], [])
end

function SCPParam(model::DoubleIntR2, fixed_final_time::Bool)
  convergence_threshold = 0.01

  SCPParam(fixed_final_time, convergence_threshold)
end

function SCPParam_GuSTO(model::DoubleIntR2)
  Δ0 = 1.
  ω0 = 1.
  ω_max = 1.0e10
  ε = 1.0e-6
  ρ0 = 0.01
  ρ1 = 0.3
  β_succ = 2.
  β_fail = 0.5
  γ_fail = 10.

  SCPParam_GuSTO(Δ0, ω0, ω_max, ε, ρ0, ρ1, β_succ, β_fail, γ_fail)
end

###############
# Gurobi stuff
###############
function cost_true(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2}) where T
  U, N = traj.U, SCPP.N
  dtp = traj_prev.dt
  Jm = 0
  for k in 1:N-1
    Jm += dtp*norm(U[:,k])^2
  end
  return Jm
end

function cost_true_convexified(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}) where {T,E}
  cost_true(traj, traj_prev, SCPP)
end

#############################
# Trajectory Initializations
#############################
function init_traj_straightline(TOP::TrajectoryOptimizationProblem{PointMassInSphere{T}, DoubleIntR2, E}) where {T,E}
  model, x_init, x_goal = TOP.PD.model, TOP.PD.x_init, TOP.PD.x_goal
  x_dim, u_dim, N, tf_guess = model.x_dim, model.u_dim, TOP.N, TOP.tf_guess
  N = TOP.N

  X = hcat(range(x_init, stop=x_goal, length=N)...)
  U = zeros(u_dim, N)
  Trajectory(X, U, tf_guess)
end

####################
# Constraint-adding 
####################
function initialize_model_params!(SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, traj_prev::Trajectory) where {T,E}
  N, robot, model = SCPP.N, SCPP.PD.robot, SCPP.PD.model
  x_dim, u_dim = model.x_dim, model.u_dim
  Xp, Up = traj_prev.X, traj_prev.U

  model.f, model.A, model.B = [], A_dyn(Xp[:,1],robot,model), B_dyn(Xp[:,1],robot,model)
  for k = 1:N-1
    push!(model.f, f_dyn(Xp[:,k],Up[:,k],robot,model))
  end
end

function update_model_params!(SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, traj_prev::Trajectory) where {T,E}
  N, robot, model = SCPP.N, SCPP.PD.robot, SCPP.PD.model
  Xp, Up, f = traj_prev.X, traj_prev.U, model.f

  for k = 1:N-1
    update_f!(f[k], Xp[:,k], Up[:,k], robot, model)
  end
end

macro constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)
  quote
    X, U, Tf = $(esc(traj)).X, $(esc(traj)).U, $(esc(traj)).Tf
    Xp, Up, Tfp, dtp = $(esc(traj_prev)).X, $(esc(traj_prev)).U, $(esc(traj_prev)).Tf, $(esc(traj_prev)).dt
    robot, model, WS, x_init, x_goal = $(esc(SCPP)).PD.robot, $(esc(SCPP)).PD.model, $(esc(SCPP)).WS, $(esc(SCPP)).PD.x_init, $(esc(SCPP)).PD.x_goal
    x_dim, u_dim, N, dh = model.x_dim, model.u_dim, $(esc(SCPP)).N, $(esc(SCPP)).dh
    X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh
  end
end

## Dynamics constraints
function dynamics_constraints(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int) where {T,E}
  # Where i is the state index, and k is the timestep index
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)

  return A_dyn_discrete(X[:,k],dtp,robot,model)*X[:,k] + B_dyn_discrete(X[:,k],dtp,robot,model)*U[:,k] - X[:,k+1]
end

# Get current dynamics structures for a time step
get_f(k::Int, model::DoubleIntR2) = model.f[k]
get_A(k::Int, model::DoubleIntR2) = model.A
get_B(k::Int, model::DoubleIntR2) = model.B

# Generate full dynamics structures for a time step
function f_dyn(x::Vector, u::Vector, robot::Robot, model::DoubleIntR2)
  x_dim = model.x_dim
  f = zeros(x_dim)
  update_f!(f, x, u, robot, model)
  return f
end

function update_f!(f, x::Vector, u::Vector, robot::Robot, model::DoubleIntR2)
  f[3:4] = 1/robot.mass*u
end

function A_dyn(x::Vector, robot::Robot, model::DoubleIntR2)
  kron([0 1; 0 0], Eye(2))
end

function B_dyn(x::Vector, robot::Robot, model::DoubleIntR2)
  B = zeros(4,2)
  B[3:4,1:2] = Eye(2)/robot.mass
  return B
end

# Generate full discrete update version of dynamics matrices for a time step
# TODO(ambyld): Rename these? Initialize these once?
function A_dyn_discrete(x, dt, robot::Robot, model::DoubleIntR2)
  kron([1 dt; 0 1], Eye(2))
end

function B_dyn_discrete(x, dt, robot::Robot, model::DoubleIntR2)
  [0.5*dt^2*Eye(2);
   dt*Eye(2)]/robot.mass
end

## Convex state inequality constraints
function csi_translational_velocity_bound(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int) where {T,E}
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)
  return norm(X[3:4,k]) - robot.hard_limit_vel
end
## Convex control inequality constraints
function cci_translational_accel_bound(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int) where {T,E}
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)
  return 1/robot.mass*norm(U[1:2,k]) - robot.hard_limit_accel
end

## Nonconvex state inequality constraints
function ncsi_obstacle_avoidance_constraints(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int) where {T,E}
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)

  rb_idx, env_idx = 1, i
  env_ = WS.btenvironment_keepout

  clearance = model.clearance 

  r = get_workspace_location(traj, SCPP, k)
  dist,xbody,xobs = BulletCollision.distance(env_,rb_idx,r,env_idx)

  # See Eq. 12b in "Convex optimization for proximity maneuvering of a spacecraft with a robotic manipulator"
  return clearance - dist
end

## Nonconvex state inequality constraints (convexified)
function ncsi_body_obstacle_avoidance_constraints_convexified(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int) where {T,E}
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)

  env_ = WS.btenvironment_keepout
  env_idx = i
  clearance = model.clearance 

  # Base
  rb_idx = 1
  r0 = get_workspace_location(traj_prev, SCPP, k)
  dist, xbody, xobs = BulletCollision.distance(env_, rb_idx, r0, env_idx)
  r = get_workspace_location(traj, SCPP, k)

  if dist < SCPP.param.obstacle_toggle_distance
    # See Eq. 12b in "Convex optimization for proximity maneuvering of a spacecraft with a robotic manipulator"
    nhat = dist > 0 ?
      (xbody-xobs)./norm(xbody-xobs) :
      (xobs-xbody)./norm(xobs-xbody)

    return clearance - (dist + nhat'*(r-r0))
  else
    return 0.
  end
end

## State trust region inequality constraints
function stri_state_trust_region(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int) where {T,E}
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)
  return norm(X[:,k]-Xp[:,k])^2
end

## Convex state inequality constraints
function ctri_control_trust_region(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int) where {T,E}
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)
  return norm(U[:,k]-Up[:,k])
end

function get_workspace_location(traj, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, k::Int, i::Int=0) where {T,E}
  return [traj.X[1:2,k]; 0]
end

## Constructing full list of constraint functions
function SCPConstraints(SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}) where {T,E}
  model = SCPP.PD.model
  x_dim, u_dim, N = model.x_dim, model.u_dim, SCPP.N
  WS = SCPP.WS

  SCPC = SCPConstraints()

  ## Dynamics constraints
  for k = 1:N-1
    push!(SCPC.dynamics, (dynamics_constraints, k, 0))
  end

  ## Convex state equality constraints
  # Init and goal (add init first for convenience of getting dual)
  for i = 1:x_dim
    push!(SCPC.convex_state_eq, (cse_init_constraints, 0, i))
  end
  for i = 1:x_dim
    push!(SCPC.convex_state_eq, (cse_goal_constraints, 0, i))
  end

  ## Convex state inequality constraints
  for k = 1:N
    push!(SCPC.convex_state_ineq, (csi_translational_velocity_bound, k, 0))
  end

  ## Nonconvex state equality constraints (convexified)
  nothing

  ## Nonconvex state inequality constraints (convexified)
  env_ = WS.btenvironment_keepout
  for k = 1:N, i = 1:length(env_.convex_env_components)
    push!(SCPC.nonconvex_state_convexified_ineq, (ncsi_body_obstacle_avoidance_constraints_convexified, k, i))
  end

  ## Convex control equality constraints
  nothing

  ## Convex control inequality constraints
  for k = 1:N-1
    push!(SCPC.convex_control_ineq, (cci_translational_accel_bound, k, 0))
  end

  ## State trust region ineqality constraints
  for k = 1:N
    push!(SCPC.state_trust_region_ineq, (stri_state_trust_region, k, 0))
  end

  ## Constrol trust region inequality constraints
  for k = 1:N-1
    push!(SCPC.control_trust_region_ineq, (ctri_control_trust_region, k, 0))
  end

  return SCPC
end

# TODO: Generalize this? Need to make A always a vector
function trust_region_ratio_gusto(traj, traj_prev::Trajectory, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}) where {T,E}
  # Where i is the state index, and k is the timestep index
  X,U,Tf,Xp,Up,Tfp,dtp,robot,model,WS,x_init,x_goal,x_dim,u_dim,N,dh = @constraint_abbrev_DoubleIntR2(traj, traj_prev, SCPP)
  fp, Ap = model.f, model.A
  num,den = 0, 0 
  env_ = WS.btenvironment_keepout

  for k in 1:N-1
    linearized = fp[k] + Ap*(X[:,k]-Xp[:,k])
    num += norm(f_dyn(X[:,k],U[:,k],robot,model) - linearized)
    den += norm(linearized)
  end
  
  clearance = model.clearance 

  # TODO(ambyld): Update for arm
  for k in 1:N
    r0 = get_workspace_location(traj, SCPP, k)
    r = get_workspace_location(traj_prev, SCPP, k)
    for (rb_idx, body_point) in enumerate(env_.convex_robot_components)
      for (env_idx,convex_env_component) in enumerate(env_.convex_env_components)
        dist,xbody,xobs = BulletCollision.distance(env_,rb_idx,r0,env_idx)
        nhat = dist > 0 ?
          (xbody-xobs)./norm(xbody-xobs) :
          (xobs-xbody)./norm(xobs-xbody) 
        linearized = clearance - (dist + nhat'*(r-r0))
        
        dist,xbody,xobs = BulletCollision.distance(env_,rb_idx,r,env_idx)

        num += abs((clearance-dist) - linearized) 
        den += abs(linearized) 
      end
    end
  end
  return num/den
end

function get_dual_cvx(prob::Convex.Problem, SCPP::SCPProblem{PointMassInSphere{T}, DoubleIntR2, E}, solver) where {T,E}
  if solver == "Mosek"
    return -MathProgBase.getdual(prob.model)[1:SCPP.PD.model.x_dim]
  else
    return []
  end
end
