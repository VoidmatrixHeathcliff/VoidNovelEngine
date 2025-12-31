#include "module_micro_pather.h"

#include <LuaBridge.h>
#include <micropather.h>

using StateList = MP_VECTOR<void*>;
using CostList = MP_VECTOR<micropather::StateCost>;

class CustomGraph : public micropather::Graph
{
public:
	CustomGraph(luabridge::LuaRef func_LeastCostEstimate, luabridge::LuaRef func_AdjacentCost, lua_State* L)
		: L(L), func_LeastCostEstimate(func_LeastCostEstimate), func_AdjacentCost(func_AdjacentCost) { }

	~CustomGraph() = default;

	float LeastCostEstimate(void* stateStart, void* stateEnd) override
	{
		luabridge::LuaResult result = func_LeastCostEstimate((intptr_t)stateStart, (intptr_t)stateEnd);
		if (!result.wasOk()) luaL_error(L, result.errorMessage().c_str());
		if (result.size() < 1) luaL_error(L, "expected 1 return value, got 0");
		return result[0];
	}

	void AdjacentCost(void* state, MP_VECTOR<micropather::StateCost>* adjacent) override
	{
		luabridge::LuaResult result = func_AdjacentCost((intptr_t)state, adjacent);
		if (!result.wasOk()) luaL_error(L, result.errorMessage().c_str());
	}

	void PrintStateInfo(void* state) { }

private:
	lua_State* L = nullptr;
	luabridge::LuaRef func_LeastCostEstimate;
	luabridge::LuaRef func_AdjacentCost;

};

struct SolveResult
{
	int status = 0;
	float cost = 0;
};

void init_micro_pather_module(lua_State* L)
{
	luabridge::getGlobalNamespace(L)
		.beginNamespace("Engine")
			.beginNamespace("MicroPather")
				// enum
				.beginNamespace("Result")
					.addVariable("SOLVED", micropather::MicroPather::SOLVED)
					.addVariable("NO_SOLUTION", micropather::MicroPather::NO_SOLUTION)
					.addVariable("START_END_SAME", micropather::MicroPather::START_END_SAME)
				.endNamespace()
				.addVariable("MAX_COST", FLT_MAX)
				// usertype
				.beginClass<CostList>("CostList")
					.addFunction("push", +[](CostList* list, intptr_t state, float cost) { list->push_back({ (void*)state, cost }); })
				.endClass()
				.beginClass<StateList>("StateList")
					.addFunction("size", +[](const StateList& list) { return list.size(); })
					.addFunction("get", +[](const StateList& list, unsigned idx) { return (intptr_t)(list[idx]); })
					.addConstructor(+[](void* ptr) { return new (ptr) StateList(); })
				.endClass()
				.beginClass<SolveResult>("SolveResult")
					.addProperty("status", &SolveResult::status)
					.addProperty("cost", &SolveResult::cost)
				.endClass()
				.beginClass<CustomGraph>("Graph")
					.addConstructor(+[](void* ptr, luabridge::LuaRef func_LeastCostEstimate, luabridge::LuaRef func_AdjacentCost, lua_State* L)
						{
							luaL_argexpected(L, func_LeastCostEstimate.isFunction(), 1, "function");
							luaL_argexpected(L, func_AdjacentCost.isFunction(), 2, "function");
							return new (ptr) CustomGraph(func_LeastCostEstimate, func_AdjacentCost, L);
						})
				.endClass()
				.beginClass<micropather::MicroPather>("MicroPather")
					.addFunction("solve", +[](micropather::MicroPather* mp, intptr_t startState, intptr_t endState, MP_VECTOR<void*>* path, lua_State* L)
						{
							SolveResult result;
							result.status = mp->Solve((void*)startState, (void*)endState, path, &result.cost);
							return result;
						})
					.addFunction("reset", &micropather::MicroPather::Reset)
					.addConstructor(+[](void* ptr, CustomGraph* graph, luabridge::LuaRef allocate, luabridge::LuaRef typicalAdjacent, luabridge::LuaRef cache)
						{ return new (ptr) micropather::MicroPather(graph, allocate ? allocate : 250, typicalAdjacent ? typicalAdjacent : 8, cache ? cache : 250); })
				.endClass()
			.endNamespace()
		.endNamespace();
}