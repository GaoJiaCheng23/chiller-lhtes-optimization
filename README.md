# Chiller–LHTES Capacity and Rolling Operation Optimization

MATLAB implementation of a coordinated chiller-dispatch and latent heat thermal energy storage (LHTES) optimization model for data-center cooling systems.

The code represents temperature- and part-load-dependent chiller performance, chiller commitment, cooling-load allocation, storage charging/discharging, auxiliary electricity consumption, and time-of-use pricing. It solves a 24-hour receding-horizon optimization problem at a 1-hour time step using YALMIP and CPLEX.

**Related manuscript:** *Coordinated Design for Latent Heat Thermal Energy Storage Capacity and Operating Strategy Considering Chiller Off-Design Performance in Data Centers* (publication details to be added).

## Repository contents

| File | Purpose |
| --- | --- |
| `chiller_lhtes_rolling_optimization.m` | Main MATLAB script for hourly rolling optimization and scenario simulation |
| `input_example.xlsx` | 72-hour **synthetic** sample input; does not contain actual site measurements |
| `README.md` | Setup, data format, model settings and outputs |
| `CITATION.cff` | Software citation metadata |
| `LICENSE` | MIT license for this repository's original source code |

## Requirements

- MATLAB (a version supporting `readtable`, `datetime`, `parfor`, and local functions in scripts)
- [YALMIP](https://yalmip.github.io/)
- IBM ILOG CPLEX with a valid license and a working MATLAB interface (default solver)
- Optional: MATLAB Parallel Computing Toolbox for parallel multi-scenario execution

Install and configure YALMIP and the solver separately; their software and licenses are not distributed here. The solver setting in the script may be changed to `gurobi` if an appropriate installation is available.

## Quick start

1. Download or clone the repository, keeping the MATLAB script and the sample workbook in the **same directory**.
2. Add YALMIP and CPLEX to your MATLAB path and confirm their availability.
3. Set MATLAB's current folder to the repository directory.
4. Run:

   ```matlab
   chiller_lhtes_rolling_optimization
   ```

The repository version runs **one demonstration scenario** by default: 4,000 RTh, energy weight `0.7`, cost weight `0.3`, using the supplied 72-hour synthetic data (`RUN_BATCH = false`, `RUN_PARALLEL = false`). This configuration demonstrates how to run the implementation; its results are **not** the annual results reported in the manuscript.

## Input data

The script loads the Excel file specified by `input_file` near the beginning of the main script. It reads the first three columns and the **last column** in the following order:

| Position | Example header | Meaning | Unit |
| --- | --- | --- | --- |
| 1 | `Time` | Start and end of the hourly interval, e.g. `2025-05-12 00:00 - 2025-05-12 01:00` | Local time |
| 2 | `CoolingWaterSupplyTemp_C` | Cooling-water supply / condenser entering fluid temperature (CEFT), used for chiller COP | °C |
| 3 | `CoolingLoad_kW` | Cooling demand | kW |
| Last | `OutdoorAirTemp_C` | Outdoor dry-bulb air temperature, used to identify high-temperature tariff days | °C |

One row represents one hour. For high-temperature tariff classification, a day's maximum outdoor air temperature of at least 35 °C triggers the high-temperature-day rate where the tariff function defines one. Additional columns between the third and last columns are not used by this script.

The original full-year site dataset is **not included**. `input_example.xlsx` is synthetic and is provided solely as an input-format and execution example. No original measured records can be reconstructed from it.

## Configuration

Adjust the following settings in `chiller_lhtes_rolling_optimization.m`:

- `input_file`: path to the Excel input.
- `RUN_BATCH`: `false` for one configuration; `true` to run `CASE_MATRIX` (capacity in RTh, energy weight `alpha`).
- `SOC_MAX`, `W_ENERGY`, `W_COST`: single-scenario configuration when `RUN_BATCH = false`.
- `CASE_MATRIX`: candidate capacity–weight pairs when `RUN_BATCH = true`. The supplied matrix contains **11 selected combinations** (including configurations examined along the effective Pareto frontier), not the full scan.
- `RUN_PARALLEL`, `N_WORKERS`, `SOLVER_THREADS`: optional parallel scenario execution and solver resource settings.
- `SOLVER_NAME`: optimization solver.

To generate the complete manuscript-style scan instead of the selected 11 cases, replace the `CASE_MATRIX` definition with:

```matlab
[capacity_grid, alpha_grid] = ndgrid(0:1000:15000, 0:0.1:1);
CASE_MATRIX = [capacity_grid(:), alpha_grid(:)];
```

This creates **176 combinations** and should be used only with appropriate computational resources and a suitable full-year input dataset.

Key model settings in the script include three modeled 1,300 RT chillers; a 0.2–0.9 operating PLR range; five chiller operating points for convex-combination approximation; 24-hour rolling horizon; 1-hour time step; 0.97 charging efficiency; 0.96 discharging efficiency; 2% nominal daily storage loss; and maximum charging/discharging thermal power of 25% of storage capacity per hour. The energy/cost objective uses the pre-retrofit annual baseline values specified in the code.

## Outputs

For each configuration, the script writes an `.xlsx` result file with:

- `Hourly_Result`: hourly chiller states, output and power, storage operation, SOC, electricity cost, and solver diagnostics.
- `Summary`: aggregated energy use, cost, operation and feasibility indicators.
- `Case_Summary`: scenario-level totals for batch analysis.
- `Failure_Log`: only when a rolling optimization step uses fallback dispatch.

A separate `batch_summary_all_cases_hourly_loss.xlsx` summarizes completed scenarios. Output workbooks are ignored by Git to prevent accidental commits of simulation results or private input data.

The script provides hourly dispatch and annual-aggregate metrics **when run with a full-year dataset**. ALCC, Pareto screening, and ICER calculations described in the manuscript are downstream evaluations and are **not implemented by this MATLAB script**.

## Data availability and reproducibility

The complete measured operating dataset is not public. The synthetic workbook supports input-format verification and demonstrative runs, but cannot reproduce site-specific figures, annual savings, or selected optimal designs reported in the manuscript. Those outcomes require the actual operating dataset, the relevant model assumptions, and compatible MATLAB/solver versions.

## License

The original source code in this repository is available under the [MIT License](LICENSE). MATLAB, YALMIP, CPLEX, and any other third-party software are subject to their own licenses.
