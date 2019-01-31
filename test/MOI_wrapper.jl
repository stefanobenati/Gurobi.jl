using MathOptInterface

const MOI  = MathOptInterface
const MOIT = MathOptInterface.Test
const MOIB = MathOptInterface.Bridges

@testset "Unit Tests" begin
    config = MOIT.TestConfig()
    solver = Gurobi.Optimizer(OutputFlag=0)
    MOIT.basic_constraint_tests(solver, config)
    MOIT.unittest(solver, config,
        ["solve_affine_interval", "solve_qcp_edge_cases"])
    @testset "solve_affine_interval" begin
        MOIT.solve_affine_interval(
            MOIB.SplitInterval{Float64}(Gurobi.Optimizer(OutputFlag=0)),
            config
        )
    end
    @testset "solve_qcp_edge_cases" begin
        MOIT.solve_qcp_edge_cases(solver,
            MOIT.TestConfig(atol=1e-3)
        )
    end
    MOIT.modificationtest(solver, config, [
        "solve_func_scalaraffine_lessthan"
    ])
end

@testset "Linear tests" begin
    @testset "Default Solver"  begin
        solver = Gurobi.Optimizer(OutputFlag=0)
        MOIT.contlineartest(solver, MOIT.TestConfig(), [
            # This requires interval constraint.
            "linear10",
            # This requires an infeasiblity certificate for a variable bound.
            "linear12"
        ])
    end
    @testset "linear10" begin
        MOIT.linear10test(
            MOIB.SplitInterval{Float64}(Gurobi.Optimizer(OutputFlag=0)),
            MOIT.TestConfig()
        )
    end
    @testset "No certificate" begin
        MOIT.linear12test(
            Gurobi.Optimizer(OutputFlag=0, InfUnbdInfo=0),
            MOIT.TestConfig(infeas_certificates=false)
        )
    end
end

@testset "Quadratic tests" begin
    MOIT.contquadratictest(
        Gurobi.Optimizer(OutputFlag=0),
        MOIT.TestConfig(atol=1e-3, rtol=1e-3, duals=false, query=false)
    )
end

@testset "Linear Conic tests" begin
    MOIT.lintest(
        Gurobi.Optimizer(OutputFlag=0),
        MOIT.TestConfig()
    )
end

@testset "Integer Linear tests" begin
    MOIT.intlineartest(
        Gurobi.Optimizer(OutputFlag=0),
        MOIT.TestConfig(),
        ["int3"]  # int3 has interval constriants
    )
    @testset "int3" begin
        MOIT.int3test(
            MOIB.SplitInterval{Float64}(Gurobi.Optimizer(OutputFlag=0)),
            MOIT.TestConfig()
        )
    end
end
@testset "ModelLike tests" begin
    solver = Gurobi.Optimizer()
    @test MOI.get(solver, MOI.SolverName()) == "Gurobi"
    @testset "default_objective_test" begin
         MOIT.default_objective_test(solver)
     end
     @testset "default_status_test" begin
         MOIT.default_status_test(solver)
     end
    @testset "nametest" begin
        MOIT.nametest(solver)
    end
    @testset "validtest" begin
        MOIT.validtest(solver)
    end
    @testset "emptytest" begin
        MOIT.emptytest(solver)
    end
    @testset "orderedindicestest" begin
        MOIT.orderedindicestest(solver)
    end
    @testset "copytest" begin
        MOIT.copytest(solver, Gurobi.Optimizer())
    end
end

@testset "Gurobi Callback" begin
    @testset "Generic callback" begin
        m = Gurobi.Optimizer(OutputFlag=0)
        x = MOI.add_variable(m)
        MOI.add_constraint(m, MOI.SingleVariable(x), MOI.GreaterThan(1.0))
        MOI.set(m, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
            MOI.ScalarAffineFunction{Float64}(
                [MOI.ScalarAffineTerm{Float64}(1.0, x)],
                0.0
            )
        )

        cb_calls = Int32[]
        function callback_function(cb_data::Gurobi.CallbackData, cb_where::Int32)
            push!(cb_calls, cb_where)
            nothing
        end

        MOI.set(m, Gurobi.CallbackFunction(), callback_function)
        MOI.optimize!(m)

        @test length(cb_calls) > 0
        @test Gurobi.CB_MESSAGE in cb_calls
        @test Gurobi.CB_PRESOLVE in cb_calls
        @test !(Gurobi.CB_MIPSOL in cb_calls)
    end

    @testset "Lazy cut" begin
        m = Gurobi.Optimizer(OutputFlag=0, Cuts=0, Presolve=0, Heuristics=0, LazyConstraints=1)
        MOI.Utilities.loadfromstring!(m,"""
            variables: x, y
            maxobjective: y
            c1: x in Integer()
            c2: y in Integer()
            c3: x in Interval(0.0, 2.0)
            c4: y in Interval(0.0, 2.0)
        """)
        x = MOI.get(m, MOI.VariableIndex, "x")
        y = MOI.get(m, MOI.VariableIndex, "y")

        # We now define our callback function that takes two arguments:
        #   (1) the callback handle; and
        #   (2) the location from where the callback was called.
        # Note that we can access m, x, and y because this function is defined
        # inside the same scope
        cb_calls = Int32[]
        function callback_function(cb_data::Gurobi.CallbackData, cb_where::Int32)
            push!(cb_calls, cb_where)
            if cb_where == Gurobi.CB_MIPSOL
                Gurobi.loadcbsolution!(m, cb_data, cb_where)
                x_val = MOI.get(m, MOI.VariablePrimal(), x)
                y_val = MOI.get(m, MOI.VariablePrimal(), y)
                # We have two constraints, one cutting off the top
                # left corner and one cutting off the top right corner, e.g.
                # (0,2) +---+---+ (2,2)
                #       |xx/ \xx|
                #       |x/   \x|
                #       |/     \|
                # (0,1) +       + (2,1)
                #       |       |
                # (0,0) +---+---+ (2,0)
                TOL = 1e-6  # Allow for some impreciseness in the solution
                if y_val - x_val > 1 + TOL
                    Gurobi.cblazy!(cb_data, m,
                        MOI.ScalarAffineFunction{Float64}(
                            MOI.ScalarAffineTerm.([-1.0, 1.0], [x, y]),
                            0.0
                        ),
                        MOI.LessThan{Float64}(1.0)
                    )
                elseif y_val + x_val > 3 + TOL
                    Gurobi.cblazy!(cb_data, m,
                        MOI.ScalarAffineFunction{Float64}(
                            MOI.ScalarAffineTerm.([1.0, 1.0], [x, y]),
                            0.0
                        ),
                        MOI.LessThan{Float64}(3.0)
                    )
                end
            end
        end

        MOI.set(m, Gurobi.CallbackFunction(), callback_function)
        MOI.optimize!(m)

        @test MOI.get(m, MOI.VariablePrimal(), x) == 1
        @test MOI.get(m, MOI.VariablePrimal(), y) == 2

        @test length(cb_calls) > 0
        @test Gurobi.CB_MESSAGE in cb_calls
        @test Gurobi.CB_PRESOLVE in cb_calls
        @test Gurobi.CB_MIPSOL in cb_calls
    end
end

@testset "LQOI Issue #38" begin
    # https://github.com/JuliaOpt/LinQuadOptInterface.jl/issues/38#issuecomment-407625187
    _getinner(opt::Gurobi.Optimizer) = opt.inner
    @inferred _getinner(Gurobi.Optimizer())
end

@testset "User limit handling (issue #140)" begin
    # Verify that we return the correct status codes when a mixed-integer
    # problem has been solved to a *feasible* but not necessarily optimal
    # solution. To do that, we will set up an intentionally dumbed-down
    # Gurobi Gurobi.Optimizer (with all heuristics and pre-solve turned off) and
    # ask it to solve a classic knapsack problem. Setting SolutionLimit=1
    # forces the solver to return after its first feasible MIP solution,
    # which tests the right part of the code without relying on potentially
    # flaky or system-dependent time limits.
    m = Gurobi.Optimizer(OutputFlag=0,
                        SolutionLimit=1,
                        Heuristics=0.0,
                        Presolve=0)
    N = 100
    x = MOI.add_variables(m, N)
    for xi in x
        MOI.add_constraint(m, MOI.SingleVariable(xi), MOI.ZeroOne())
        MOI.set(m, MOI.VariablePrimalStart(), xi, 0.0)
    end
    # Given a collection of items with individual weights and values,
    # maximize the total value carried subject to the constraint that
    # the total weight carried is less than 10.
    if VERSION >= v"0.7-"
        Random.seed!(1)
    else
        srand(1)
    end
    item_weights = rand(N)
    item_values = rand(N)
    MOI.add_constraint(m,
        MOI.ScalarAffineFunction(MOI.ScalarAffineTerm.(item_weights, x), 0.0),
        MOI.LessThan(10.0))
    MOI.set(m, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        MOI.ScalarAffineFunction(MOI.ScalarAffineTerm.(.-item_values, x), 0.0))
    MOI.optimize!(m)

    @test MOI.get(m, MOI.TerminationStatus()) == MOI.SOLUTION_LIMIT
    # We should have a primal feasible solution:
    @test MOI.get(m, MOI.PrimalStatus()) == MOI.FEASIBLE_POINT
    # But we have no dual status:
    @test MOI.get(m, MOI.DualStatus()) == MOI.NO_SOLUTION
end

@testset "Constant objective (issue #111)" begin
    m = Gurobi.Optimizer()
    x = MOI.add_variable(m)
    MOI.set(m, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[], 2.0))
    @test MOI.get(m, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}()).constant == 2.0
    @test Gurobi.get_dblattr(m.inner, "ObjCon") == 2.0

    MOI.modify(m, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(), MOI.ScalarConstantChange(3.0))
    @test MOI.get(m, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}()).constant == 3.0
    @test Gurobi.get_dblattr(m.inner, "ObjCon") == 3.0
end

@testset "Test mutiple Env's" begin
    env = Gurobi.Env()
    model_1 = Gurobi.Optimizer(env)
    model_2 = Gurobi.Optimizer(env)
    @test model_1.inner.env.ptr_env == model_2.inner.env.ptr_env
end
