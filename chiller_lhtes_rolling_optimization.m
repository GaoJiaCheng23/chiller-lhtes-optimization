
%% =========================
%为了避免冷水机组频繁启停，冷水机组的连续运行限制设为 3 h [32]，即 R 等于 3。在算法优化过程中，可能会出现无法满足约束条件的情况。如果 R 为 3，并且在优化过程中没有解决方案，则会自动降级，直到 R 为 1。
%% =========================
clc;
clear;
close all;

%% =========================
% 全天24h滚动优化
% 三台冷机独立建模
% 每台冷机最小连续运行时长：
% 先 R=3，无解则 R=2，再无解则 R=1
%% =========================

%% =========================
% 1. 文件与参数
% =========================
input_file  = 'input_example.xlsx';
output_file = 'result.xlsx';

% ---- 冷机总台数 ----
N_CHILLER = 3;

% ---- 单台冷机额定制冷量 (kW) ----
Q_RATED_SINGLE = 1300 * 3.517;

% ---- 冷机负载率范围 ----
PLR_MIN = 0.2;
PLR_MAX = 0.9;

% ---- 蓄冷容量上限 (kWh) ----
SOC_MAX = 4000 * 3.517;

% ---- 蓄冷效率 ----
ETA_CH  = 0.97;
ETA_DIS = 0.96;

% ---- 24 h 热损失率（由实验取得）----
DAILY_LOSS = 0.02;

% ---- 时间步长 (h) ----
DT = 1.0;

% ---- 将24 h 2%的衰减换算为等效单步损失率 ----
% 满足 (1 - HOURLY_LOSS)^(24/DT) = 1 - DAILY_LOSS
% 当DT=1 h时约为0.0008416，与DAILY_LOSS/24的近似相差很小。
HOURLY_LOSS = 1 - (1 - DAILY_LOSS)^(DT / 24);

% ---- 蓄冷/放冷额定功率：每小时最多为储能容量的 25% ----
% SOC_MAX 为 kWh，除以 DT 后为 kW；充冷与放冷分别受限。
STORAGE_POWER_FRACTION = 0.25;

% ---- 全天滚动优化窗口 ----
H_ROLL = 24;

% ---- 分段线性化断点个数 ----
N_SEG = 5;

% ---- 未满足负荷惩罚系数 ----
PENALTY_UNMET = 1e4;

% ---- 冷机启动惩罚参数 ----
% E_START_EQ: 单台冷机单次启动的等效电耗，kWh/次
% C_START_EQ: 单台冷机单次启动的等效维护成本，元/次
% 注意：这不是严格物理启动电耗，而是等效调度惩罚参数，建议后续做敏感性分析。
E_START_EQ = 0;
C_START_EQ = 0;

% ---- 辅助设备等效功耗系数 ----
% 单位：kWe/kWc
% Paux = AUX_DIR*Qdir + AUX_CH*Qch + AUX_DIS*Qdis + AUX_CW*Qtotal + AUX_CT*Qtotal + P_FIXED_ON*n_on
AUX_DIR = 0.01;   % 冷机直供侧冷冻水泵/分配侧辅助功耗
AUX_CH  = 0.01;   % 蓄冷充冷侧辅助功耗
AUX_DIS = 0.01;   % 蓄冷释冷侧辅助功耗
AUX_CW  = 0.010;   % 冷却水泵等效功耗，仅冷机运行时产生
AUX_CT  = 0.02;   % 冷却塔风机等效功耗，仅冷机运行时产生
P_FIXED_ON = 0;    % 每台冷机开机附属固定功耗，kW/台

% ---- 最小连续运行时长：初值与下限 ----
R_INIT = 3;
R_MIN  = 1;

% ---- 原系统全年基准值 ----
BASE_ENERGY = 7258500;
BASE_COST   = 4773100;

% ---- 目标函数权重（可修改）----
% 建议先令两者和为1，便于解释
W_ENERGY = 0.7;  % 节能权重
W_COST   = 0.3;   % 节费权重

% ---- 求解器 ----
SOLVER_NAME = 'cplex';   % 可改为 'gurobi'

% ---- 是否启用热启动 ----
USE_WARMSTART = true;

% ---- 批量灵敏度分析设置：蓄冷容量 × 优化目标 ----
% 容量单位为 RT-h；程序内部会转换为 kWh。按需要增删容量点。
RUN_BATCH = false;

% 每行：[LHTES容量(RTh), 节能权重alpha]
CASE_MATRIX = [
    5000, 0.3;
    4000, 0.1;
    4000, 0.3;
    4000, 0.5;
    4000, 0.7;
    1000, 0.7;
    1000, 0.8;
       0, 0.2;
    1000, 1.0;
    3000, 1.0;
    6000, 1.0
];

PROGRESS_EVERY = 24;   % 每隔多少个滚动步打印一次进度；设为 24 可按天刷新
MAKE_PLOTS = ~RUN_BATCH;  % 批量分析默认不弹图，避免每个案例生成大量图窗
RUN_PARALLEL = false;  % 批量案例并行计算；需要 Parallel Computing Toolbox
N_WORKERS = 24;         % 128 核、至少 128 GB 内存的服务器：24 个案例并行；可按服务器负载调整
SOLVER_THREADS = 4;     % 并行时每个 CPLEX/Gurobi 实例最多使用的 CPU 线程
MAX_AUTO_WORKERS = 32;  % 自动模式的并行案例上限（128 核时最多 32×4 线程）
RAM_PER_WORKER_GB = 3;  % 按每个 MATLAB worker 约 3 GB 预留内存

%% =========================
% 2. 读取数据
% =========================
T_in = readtable(input_file);
T_in.Properties.VariableNames = matlab.lang.makeValidName(T_in.Properties.VariableNames);
if width(T_in) < 4
    error('Input data must include outdoor temperature in its last column.');
end

time_col = T_in.Properties.VariableNames{1};
temp_col = T_in.Properties.VariableNames{2};
load_col = T_in.Properties.VariableNames{3};
ambient_col = T_in.Properties.VariableNames{end};

time_raw = T_in.(time_col);
T_out    = T_in.(temp_col);
Q_load   = T_in.(load_col);
T_ambient = T_in.(ambient_col);

% ---- 时间转 datetime ----
if iscell(time_raw) || isstring(time_raw) || ischar(time_raw)
    time_str = string(time_raw);
    time_str = strtrim(time_str);

    if contains(time_str(1), " - ")
        time_str = extractBefore(time_str, " - ");
        dt = datetime(time_str, ...
            'InputFormat', 'yyyy-MM-dd HH:mm', ...
            'Format', 'yyyy-MM-dd HH:mm:ss');
    else
        try
            dt = datetime(time_str, ...
                'InputFormat', 'yyyy-MM-dd HH:mm:ss', ...
                'Format', 'yyyy-MM-dd HH:mm:ss');
        catch
            dt = datetime(time_str, ...
                'InputFormat', 'yyyy-MM-dd HH:mm', ...
                'Format', 'yyyy-MM-dd HH:mm:ss');
        end
    end
else
    dt = datetime(time_raw, ...
        'ConvertFrom', 'excel', ...
        'Format', 'yyyy-MM-dd HH:mm:ss');
end

N = length(Q_load);
input_location = input_file;
[input_found, input_attributes] = fileattrib(input_file);
if input_found
    input_location = input_attributes.Name;
end
fprintf('Input: %s | %d hourly rows | %s to %s | H_ROLL=%d | solver=%s\n', ...
    input_location, N, string(dt(1)), string(dt(end)), H_ROLL, SOLVER_NAME);

month_vec = month(dt);
hour_vec  = hour(dt);
date_vec  = dateshift(dt, 'start', 'day');

%% =========================
% 3. 高温天标记
% =========================
is_hot_day = false(N, 1);
day_list_all = unique(date_vec);

for d = 1:length(day_list_all)
    idxd = (date_vec == day_list_all(d));
    Tmax_day = max(T_ambient(idxd));
    if Tmax_day >= 35
        is_hot_day(idxd) = true;
    end
end

%% =========================
% 4. 电价向量
% =========================
price_vec = zeros(N, 1);
for i = 1:N
    price_vec(i) = get_tou_price(month_vec(i), hour_vec(i), is_hot_day(i));
end

%% =========================
% 5. 单台冷机分段点预计算
% =========================
PLR_break = linspace(PLR_MIN, PLR_MAX, N_SEG);
K = length(PLR_break);

Q_break_single = zeros(N, K);
P_break_single = zeros(N, K);

for t = 1:N
    T = T_out(t);
    for k = 1:K
        plr = PLR_break(k);
        Q_single = plr * Q_RATED_SINGLE;
        COP_single = max(cop_func(T, plr), 0.1);
        P_single = Q_single / COP_single;

        Q_break_single(t, k) = Q_single;
        P_break_single(t, k) = P_single;
    end
end

%% =========================
% 6. 预分配结果变量
% =========================
if RUN_BATCH
    % 每行：[容量, 节能权重, 节费权重]
    case_matrix = [
        CASE_MATRIX(:,1), ...
        CASE_MATRIX(:,2), ...
        1 - CASE_MATRIX(:,2)
    ];
else
    case_matrix = [SOC_MAX / 3.517, W_ENERGY, W_COST];
end

total_cases = size(case_matrix, 1);
batch_tic = tic;
BatchSummaryCell = cell(total_cases, 1);

if RUN_PARALLEL && total_cases > 1
    cluster = parcluster;
    if isempty(N_WORKERS)
        try
            cpu_cores = feature('numcores');
        catch
            cpu_cores = maxNumCompThreads;
        end
        cpu_limit = max(1, floor(cpu_cores / SOLVER_THREADS));
        try
            [~, memory_info] = memory;
            total_ram_gb = memory_info.PhysicalMemory.Total / 1024^3;
            available_ram_gb = memory_info.PhysicalMemory.Available / 1024^3;
            reserve_ram_gb = max(4, 0.1 * total_ram_gb);
            ram_limit = max(1, floor((available_ram_gb - reserve_ram_gb) / RAM_PER_WORKER_GB));
        catch
            available_ram_gb = NaN;
            ram_limit = cluster.NumWorkers;
        end
        target_workers = min([total_cases, MAX_AUTO_WORKERS, cpu_limit, ram_limit]);
        fprintf('Auto parallel sizing: %d CPU cores, %.1f GB available RAM, CPU limit %d, RAM limit %d -> %d workers\n', ...
            cpu_cores, available_ram_gb, cpu_limit, ram_limit, target_workers);
    else
        target_workers = max(1, min(total_cases, floor(N_WORKERS)));
    end
    pool = gcp('nocreate');
    if isempty(pool)
        cluster.NumWorkers = max(cluster.NumWorkers, target_workers);
        pool = parpool(cluster, target_workers);
    elseif pool.NumWorkers ~= target_workers
        fprintf('Recreating parallel pool: %d -> %d workers\n', pool.NumWorkers, target_workers);
        delete(pool);
        cluster.NumWorkers = max(cluster.NumWorkers, target_workers);
        pool = parpool(cluster, target_workers);
    end
    parfor_workers = pool.NumWorkers;
    fprintf('Parallel cases: %d workers, %d solver threads per worker\n', ...
        parfor_workers, SOLVER_THREADS);
    pctRunOnAll addpath(pwd);
    progress_queue = parallel.pool.DataQueue;
    afterEach(progress_queue, @(msg) print_parallel_progress(msg, total_cases, N, batch_tic));
else
    parfor_workers = 0;
    progress_queue = [];
end

parfor (case_counter = 1:total_cases, parfor_workers)

        capacity_rt = case_matrix(case_counter, 1);
        W_ENERGY = case_matrix(case_counter, 2);
        W_COST = case_matrix(case_counter, 3);

        SOC_MAX = capacity_rt * 3.517;
        Q_CH_MAX = STORAGE_POWER_FRACTION * SOC_MAX / DT;
        Q_DIS_MAX = STORAGE_POWER_FRACTION * SOC_MAX / DT;

        scenario_name = sprintf('%.1f', W_ENERGY);
        output_file = sprintf('batch_%s_%gRT_25pct_hourly_loss_result.xlsx', scenario_name, capacity_rt);
        case_tic = tic;

        fprintf('\n========== Case %d/%d: %s, storage=%g RT-h, W_ENERGY=%.3g, W_COST=%.3g ==========\n', ...
            case_counter, total_cases, scenario_name, capacity_rt, W_ENERGY, W_COST);
        drawnow;

season_str = strings(N, 1);
mode_str   = strings(N, 1);

Q_total_chiller      = zeros(N, 1);
PLR_total_chiller    = zeros(N, 1);
COP_total_chiller    = nan(N, 1);
P_total_chiller      = zeros(N, 1);

Q_direct_to_load     = zeros(N, 1);
Q_charge             = zeros(N, 1);
Q_discharge_to_load  = zeros(N, 1);
Q_storage_used       = zeros(N, 1);
E_thermal_loss       = zeros(N, 1); % 每时段环境热损失 (kWh)
unmet_load           = zeros(N, 1);

SOC_begin            = zeros(N, 1);
SOC_end              = zeros(N, 1);

P_aux_model          = zeros(N, 1);
P_sys_model          = zeros(N, 1);
P_total_model        = zeros(N, 1);
cost_case_hourly     = zeros(N, 1);

n_on_result          = zeros(N, 1);
Q_single_avg         = zeros(N, 1);
PLR_single_avg       = zeros(N, 1);
COP_single_avg       = nan(N, 1);
P_single_avg         = zeros(N, 1);

% ---- 每台机组开关状态与连续运行时长 ----
x1_result            = zeros(N, 1);
x2_result            = zeros(N, 1);
x3_result            = zeros(N, 1);

startup_total_result = zeros(N, 1);
startup1_result      = zeros(N, 1);
startup2_result      = zeros(N, 1);
startup3_result      = zeros(N, 1);

runhour1_result      = zeros(N, 1);
runhour2_result      = zeros(N, 1);
runhour3_result      = zeros(N, 1);

Q1_result            = zeros(N, 1);
Q2_result            = zeros(N, 1);
Q3_result            = zeros(N, 1);

P1_result            = zeros(N, 1);
P2_result            = zeros(N, 1);
P3_result            = zeros(N, 1);

PLR1_result          = zeros(N, 1);
PLR2_result          = zeros(N, 1);
PLR3_result          = zeros(N, 1);

COP1_result          = nan(N, 1);
COP2_result          = nan(N, 1);
COP3_result          = nan(N, 1);

% ---- 连续运行降级记录 ----
R_used_result        = nan(N, 1);

% ---- 调试/求解记录 ----
roll_window_obj      = nan(N, 1);
roll_solve_problem   = nan(N, 1);
roll_solve_info      = strings(N, 1);
roll_attempt_info    = strings(N, 1);
fallback_used        = false(N, 1);
fallback_note        = strings(N, 1);
roll_step_seconds     = zeros(N, 1);
roll_model_seconds    = zeros(N, 1);
roll_optimize_seconds = zeros(N, 1);
roll_yalmip_seconds   = zeros(N, 1);
roll_solver_seconds   = zeros(N, 1);
roll_attempt_count    = zeros(N, 1);
roll_memory_mb        = nan(N, 1);

%% =========================
% 7. 热启动缓存
% =========================
warm_x      = [];
warm_u      = [];
warm_lambda = [];
warm_Qc     = [];
warm_Pc     = [];
warm_Qtotal = [];
warm_Pch    = [];
warm_Paux   = [];
warm_Psys   = [];
warm_Qdir   = [];
warm_Qch    = [];
warm_Qdis   = [];
warm_Qunmet = [];
warm_S      = [];

%% =========================
% 8. 初始 SOC 与机组历史状态
% =========================
soc = 0.0;

% 上一时刻三台机组的实际开机状态
x_prev = zeros(1, N_CHILLER);

% 上一时刻截止，每台机组已连续运行小时数
runhour_prev = zeros(1, N_CHILLER);

%% =========================
% 9. 主循环：全天滚动优化
% =========================
ops = sdpsettings('solver', SOLVER_NAME, 'verbose', 0, 'usex0', 1);

if strcmpi(SOLVER_NAME, 'gurobi')
    ops.gurobi.TimeLimit = 10;
    ops.gurobi.MIPGap    = 0.01;
    ops.gurobi.MIPFocus  = 1;
    if RUN_PARALLEL && total_cases > 1
        ops.gurobi.Threads = SOLVER_THREADS;
    end
elseif strcmpi(SOLVER_NAME, 'cplex')
    try
        ops.cplex.timelimit = 10;
        ops.cplex.mip.tolerances.mipgap = 0.01;
        if RUN_PARALLEL && total_cases > 1
            ops.cplex.threads = SOLVER_THREADS;
        end
    catch
    end
end

for i = 1:N
    step_tic = tic;
    if mod(i - 1, PROGRESS_EVERY) == 0 || i == N
        case_elapsed = toc(case_tic);
        case_eta = case_elapsed / max(i - 1, 1) * max(N - i + 1, 0);
        if isempty(progress_queue)
            fprintf('[%s | Case %d/%d] Rolling step %d/%d (%.1f%%), case elapsed %.1f min, case ETA %.1f min\n', ...
                datestr(now, 'yyyy-mm-dd HH:MM:SS'), case_counter, total_cases, i, N, ...
                100 * i / N, case_elapsed / 60, case_eta / 60);
        else
            send(progress_queue, struct( ...
                'case_id', case_counter, ...
                'step', i, ...
                'case_elapsed', case_elapsed, ...
                'case_eta', case_eta));
        end
        drawnow;
    end

    T  = T_out(i);
    m  = month_vec(i);

    SOC_begin(i) = soc;
    % 单步环境热损失基于该步开始时的储能状态（与优化约束一致）
    E_thermal_loss(i) = HOURLY_LOSS * soc;

    % ---------- 季节判断 ----------
    if ismember(m, [3 4 5])
        season_str(i) = "spring";
    elseif ismember(m, [6 7 8])
        season_str(i) = "summer";
    elseif ismember(m, [9 10 11])
        season_str(i) = "autumn";
    else
        season_str(i) = "winter";
    end

    % ---- 构造滚动窗口 ----
    H = min(H_ROLL, N - i + 1);
    horizon_idx = i:(i + H - 1);

    solved_flag = false;
    diagnostics = [];
    R_success   = nan;
    attempt_notes = strings(0, 1);

    % =========================================================
    % 连续运行时长自动降级：R = 3 -> 2 -> 1
    % =========================================================
    for R_try = R_INIT:-1:R_MIN
        % 每次失败重试都从空的 YALMIP 数据库开始，避免同一步内叠加旧模型。
        attempt_tic = tic;
        safe_yalmip_clear();
        roll_attempt_count(i) = roll_attempt_count(i) + 1;

        % ---- YALMIP变量 ----
        x      = binvar(H, N_CHILLER, 'full');      % 每台机组开关状态
        u      = binvar(H, N_CHILLER, 'full');      % 启动变量
        lambda = sdpvar(H, N_CHILLER, K, 'full');   % 每台机组分段权重

        Qc     = sdpvar(H, N_CHILLER, 'full');      % 每台机组制冷量
        Pc     = sdpvar(H, N_CHILLER, 'full');      % 每台机组功率

        n_on   = intvar(H, 1);                      % 开机台数
        Qtotal = sdpvar(H, 1);                      % 总制冷量
        Pch    = sdpvar(H, 1);                      % 冷机总功率
        Paux   = sdpvar(H, 1);                      % 辅助设备功耗
        Psys   = sdpvar(H, 1);                      % 冷站系统总功耗

        Qdir   = sdpvar(H, 1);                      % 冷机直供负荷
        Qch    = sdpvar(H, 1);                      % 冷机充冷
        Qdis   = sdpvar(H, 1);                      % 蓄冷释冷
        Qunmet = sdpvar(H, 1);                      % 未满足负荷
        S      = sdpvar(H + 1, 1);                  % SOC

        % ---- 热启动 ----
        if USE_WARMSTART && ~isempty(warm_Qtotal)
            Hprev = length(warm_Qtotal);
            Huse  = min(H, Hprev - 1);

            if Huse >= 1
                x0      = zeros(H, N_CHILLER);
                u0      = zeros(H, N_CHILLER);
                lambda0 = zeros(H, N_CHILLER, K);
                Qc0     = zeros(H, N_CHILLER);
                Pc0     = zeros(H, N_CHILLER);
                n_on0   = zeros(H, 1);
                Qtotal0 = zeros(H, 1);
                Pch0    = zeros(H, 1);
                Paux0   = zeros(H, 1);
                Psys0   = zeros(H, 1);
                Qdir0   = zeros(H, 1);
                Qch0    = zeros(H, 1);
                Qdis0   = zeros(H, 1);
                Qunmet0 = zeros(H, 1);
                S0      = zeros(H + 1, 1);

                x0(1:Huse,:)          = warm_x(2:Huse+1,:);
                u0(1:Huse,:)          = warm_u(2:Huse+1,:);
                lambda0(1:Huse,:,:)   = warm_lambda(2:Huse+1,:,:);
                Qc0(1:Huse,:)         = warm_Qc(2:Huse+1,:);
                Pc0(1:Huse,:)         = warm_Pc(2:Huse+1,:);
                n_on0(1:Huse)         = sum(warm_x(2:Huse+1,:), 2);
                Qtotal0(1:Huse)       = warm_Qtotal(2:Huse+1);
                Pch0(1:Huse)          = warm_Pch(2:Huse+1);
                if ~isempty(warm_Paux)
                    Paux0(1:Huse) = warm_Paux(2:Huse+1);
                end
                if ~isempty(warm_Psys)
                    Psys0(1:Huse) = warm_Psys(2:Huse+1);
                end
                Qdir0(1:Huse)         = warm_Qdir(2:Huse+1);
                Qch0(1:Huse)          = warm_Qch(2:Huse+1);
                Qdis0(1:Huse)         = warm_Qdis(2:Huse+1);
                Qunmet0(1:Huse)       = warm_Qunmet(2:Huse+1);
                S0(1:Huse+1)          = warm_S(2:Huse+2);

                if Huse < H
                    x0(Huse+1:end,:) = repmat(warm_x(end,:), H-Huse, 1);

                    for hh = Huse+1:H
                        n_on0(hh)   = sum(x0(hh,:));
                        Qtotal0(hh) = 0;
                        Pch0(hh)    = 0;
                        Paux0(hh)   = 0;
                        Psys0(hh)   = 0;
                        Qdir0(hh)   = 0;
                        Qch0(hh)    = 0;
                        Qdis0(hh)   = 0;
                        Qunmet0(hh) = 0;
                    end

                    for ss = Huse+2:H+1
                        S0(ss) = S0(ss-1);
                    end
                end

                % 估计u初值
                if H >= 1
                    u0(1,:) = max(0, x0(1,:) - x_prev);
                    for hh = 2:H
                        u0(hh,:) = max(0, x0(hh,:) - x0(hh-1,:));
                    end
                end

                S0(1) = soc;

                assign(x,      round(max(0, min(1, x0))));
                assign(u,      round(max(0, min(1, u0))));
                assign(lambda, max(0, lambda0));
                assign(Qc,     max(0, Qc0));
                assign(Pc,     max(0, Pc0));
                assign(n_on,   max(0, min(N_CHILLER, round(n_on0))));
                assign(Qtotal, max(0, Qtotal0));
                assign(Pch,    max(0, Pch0));
                assign(Paux,   max(0, Paux0));
                assign(Psys,   max(0, Psys0));
                assign(Qdir,   max(0, Qdir0));
                assign(Qch,    max(0, Qch0));
                assign(Qdis,   max(0, Qdis0));
                assign(Qunmet, max(0, Qunmet0));
                assign(S,      max(0, min(SOC_MAX, S0)));
            end
        end

        % 将同一组逐时线性约束批量建立，模型含义与原循环一致。
        lambda_2d = reshape(lambda, H * N_CHILLER, K);
        Q_break_model = repmat(Q_break_single(horizon_idx, :), N_CHILLER, 1);
        P_break_model = repmat(P_break_single(horizon_idx, :), N_CHILLER, 1);

        Constraints = [ ...
            S(1) == soc, ...
            x(:,1) >= x(:,2), x(:,2) >= x(:,3), ...
            sum(lambda_2d, 2) == reshape(x, H * N_CHILLER, 1), ...
            lambda_2d >= 0, ...
            reshape(Qc, H * N_CHILLER, 1) == sum(lambda_2d .* Q_break_model, 2), ...
            reshape(Pc, H * N_CHILLER, 1) == sum(lambda_2d .* P_break_model, 2), ...
            n_on == sum(x, 2), n_on >= 1, ...
            Qtotal == sum(Qc, 2), Pch == sum(Pc, 2), ...
            Paux == AUX_DIR * Qdir + AUX_CH * Qch + AUX_DIS * Qdis ...
                  + AUX_CW * Qtotal + AUX_CT * Qtotal + P_FIXED_ON * n_on, ...
            Psys == Pch + Paux, ...
            Qtotal >= 0, Pch >= 0, Paux >= 0, Psys >= 0, ...
            Qdir >= 0, Qch >= 0, Qch <= Q_CH_MAX, ...
            Qdis >= 0, Qdis <= Q_DIS_MAX, Qunmet == 0, ...
            Qtotal == Qdir + Qch, ...
            Qdir + Qdis + Qunmet == Q_load(horizon_idx), ...
            S >= 0, S <= SOC_MAX, ...
            Qdis <= ETA_DIS * S(1:H) / DT, ...
            S(2:H+1) == (1 - HOURLY_LOSS) * S(1:H) ...
                + ETA_CH * Qch * DT - Qdis * DT / ETA_DIS ...
        ];

        hourly_coeff = 1e6 * DT * (W_ENERGY / BASE_ENERGY ...
            + W_COST * price_vec(horizon_idx) / BASE_COST);
        startup_coeff = 1e6 * (W_ENERGY * E_START_EQ / BASE_ENERGY ...
            + W_COST * C_START_EQ / BASE_COST);
        Objective = hourly_coeff' * Psys + startup_coeff * sum(u(:)) ...
            + 1e6 * PENALTY_UNMET * DT * sum(Qunmet);

        % =====================================================
        % 每台机组最小连续运行时长约束
        % =====================================================

        % ---- 启动变量定义 ----
        Constraints = [Constraints, u(1,:) >= x(1,:) - x_prev];
        Constraints = [Constraints, u(1,:) <= x(1,:)];
        Constraints = [Constraints, u(1,:) <= 1 - x_prev];

        for j = 2:H
            Constraints = [Constraints, u(j,:) >= x(j,:) - x(j-1,:)];
            Constraints = [Constraints, u(j,:) <= x(j,:)];
            Constraints = [Constraints, u(j,:) <= 1 - x(j-1,:)];
        end

        % ---- 对窗口内新启动事件施加最小连续运行时长 ----
        for j = 1:H
            j2 = min(H, j + R_try - 1);
            len_now = j2 - j + 1;
            for c = 1:N_CHILLER
                Constraints = [Constraints, ...
                    sum(x(j:j2, c)) >= len_now * u(j,c)];
            end
        end

        % ---- 若进入当前滚动步前某台机组已开机但未满R_try小时，
        %      则前若干小时必须继续保持开机 ----
        for c = 1:N_CHILLER
            if x_prev(c) == 1 && runhour_prev(c) < R_try
                remain_on = R_try - runhour_prev(c);
                remain_on = min(remain_on, H);
                Constraints = [Constraints, x(1:remain_on, c) == 1];
            end
        end

        % ---- 求解 ----
        model_seconds_try = toc(attempt_tic);
        roll_model_seconds(i) = roll_model_seconds(i) + model_seconds_try;
        optimize_tic = tic;
        try
            diagnostics_try = optimize(Constraints, Objective, ops);
        catch ME
            diagnostics_try = struct('problem', -999, ...
                'info', ['MATLAB exception: ' ME.identifier ': ' ME.message]);
        end
        optimize_seconds_try = toc(optimize_tic);
        roll_optimize_seconds(i) = roll_optimize_seconds(i) + optimize_seconds_try;
        if isfield(diagnostics_try, 'yalmiptime') && isfinite(diagnostics_try.yalmiptime)
            roll_yalmip_seconds(i) = roll_yalmip_seconds(i) + diagnostics_try.yalmiptime;
        end
        if isfield(diagnostics_try, 'solvertime') && isfinite(diagnostics_try.solvertime)
            roll_solver_seconds(i) = roll_solver_seconds(i) + diagnostics_try.solvertime;
        end
        attempt_notes(end + 1, 1) = sprintf('R=%d: problem=%d, model=%.2fs, optimize=%.2fs, info=%s', ...
            R_try, diagnostics_try.problem, model_seconds_try, optimize_seconds_try, ...
            string(diagnostics_try.info));

        if diagnostics_try.problem == 0
            diagnostics = diagnostics_try;
            solved_flag = true;
            R_success   = R_try;
            break;
        end
    end

    roll_attempt_info(i) = strjoin(attempt_notes, ' | ');

    if solved_flag
        roll_solve_problem(i) = diagnostics.problem;
        roll_solve_info(i)    = string(diagnostics.info);
        R_used_result(i)      = R_success;

        % ---- 读取当前时刻结果 ----
        x_now      = round(value(x(1,:)));
        Qc_now     = value(Qc(1,:));
        Pc_now     = value(Pc(1,:));

        Qtotal_now = value(Qtotal(1));
        Pch_now    = value(Pch(1));
        Paux_now   = value(Paux(1));
        Psys_now   = value(Psys(1));
        Qdir_now   = value(Qdir(1));
        Qch_now    = value(Qch(1));
        Qdis_now   = value(Qdis(1));
        Qunmet_now = value(Qunmet(1));
        Snext_now  = value(S(2));

        u_now      = round(value(u(1,:)));
        n_on_now   = sum(x_now);
        roll_window_obj(i) = value(Objective);
    else
        % 本窗口无法求解时，只执行当前小时的冷机直供；下一小时重新优化。
        fallback_used(i) = true;
        roll_solve_problem(i) = diagnostics_try.problem;
        roll_solve_info(i) = roll_attempt_info(i);
        [x_now, Qc_now, Pc_now, fallback_note(i)] = ...
            direct_fallback_dispatch(Q_load(i), x_prev, runhour_prev, ...
            R_INIT, N_CHILLER, Q_RATED_SINGLE, PLR_MIN, PLR_MAX, ...
            Q_break_single(i, :), P_break_single(i, :));

        Qdir_now   = Q_load(i);
        Qch_now    = 0;
        Qdis_now   = 0;
        Qunmet_now = 0;
        Qtotal_now = Qdir_now;
        Pch_now    = sum(Pc_now);
        n_on_now   = sum(x_now);
        Paux_now   = AUX_DIR * Qdir_now + AUX_CW * Qtotal_now ...
            + AUX_CT * Qtotal_now + P_FIXED_ON * n_on_now;
        Psys_now   = Pch_now + Paux_now;
        % 回退为冷机直供时仍须扣除当前小时储能热损失。
        Snext_now  = (1 - HOURLY_LOSS) * soc;
        u_now      = max(0, x_now - x_prev);

        fprintf(2, '[%s | Case %d/%d] Step %d (%s) solve failed; direct fallback. %s; %s\n', ...
            string(scenario_name), case_counter, total_cases, i, ...
            datestr(dt(i), 'yyyy-mm-dd HH:MM:SS'), ...
            roll_attempt_info(i), fallback_note(i));
    end
    startup_now = sum(u_now);

    % ---- 保存总结果 ----
    Q_total_chiller(i)     = Qtotal_now;
    Q_direct_to_load(i)    = Qdir_now;
    Q_charge(i)            = Qch_now;
    Q_discharge_to_load(i) = Qdis_now;
    unmet_load(i)          = Qunmet_now;
    n_on_result(i)         = n_on_now;

    if Q_total_chiller(i) > 1e-8
        PLR_total_chiller(i) = Q_total_chiller(i) / (N_CHILLER * Q_RATED_SINGLE);
        COP_total_chiller(i) = Q_total_chiller(i) / max(Pch_now, 1e-8);
        P_total_chiller(i)   = Pch_now;
    else
        PLR_total_chiller(i) = 0;
        COP_total_chiller(i) = NaN;
        P_total_chiller(i)   = 0;
    end

    if n_on_now >= 1 && Q_total_chiller(i) > 1e-8
        Q_single_avg(i)   = Q_total_chiller(i) / n_on_now;
        PLR_single_avg(i) = Q_single_avg(i) / Q_RATED_SINGLE;
        COP_single_avg(i) = Q_total_chiller(i) / max(P_total_chiller(i), 1e-8);
        P_single_avg(i)   = P_total_chiller(i) / n_on_now;
    else
        Q_single_avg(i)   = 0;
        PLR_single_avg(i) = 0;
        COP_single_avg(i) = NaN;
        P_single_avg(i)   = 0;
    end

    % ---- 保存单机结果 ----
    x1_result(i) = x_now(1);
    x2_result(i) = x_now(2);
    x3_result(i) = x_now(3);

    startup_total_result(i) = startup_now;
    startup1_result(i)      = u_now(1);
    startup2_result(i)      = u_now(2);
    startup3_result(i)      = u_now(3);

    Q1_result(i) = Qc_now(1);
    Q2_result(i) = Qc_now(2);
    Q3_result(i) = Qc_now(3);

    P1_result(i) = Pc_now(1);
    P2_result(i) = Pc_now(2);
    P3_result(i) = Pc_now(3);

    if x_now(1) >= 1 && Qc_now(1) > 1e-8
        PLR1_result(i) = Qc_now(1) / Q_RATED_SINGLE;
        COP1_result(i) = Qc_now(1) / max(Pc_now(1), 1e-8);
    else
        PLR1_result(i) = 0;
        COP1_result(i) = NaN;
    end

    if x_now(2) >= 1 && Qc_now(2) > 1e-8
        PLR2_result(i) = Qc_now(2) / Q_RATED_SINGLE;
        COP2_result(i) = Qc_now(2) / max(Pc_now(2), 1e-8);
    else
        PLR2_result(i) = 0;
        COP2_result(i) = NaN;
    end

    if x_now(3) >= 1 && Qc_now(3) > 1e-8
        PLR3_result(i) = Qc_now(3) / Q_RATED_SINGLE;
        COP3_result(i) = Qc_now(3) / max(Pc_now(3), 1e-8);
    else
        PLR3_result(i) = 0;
        COP3_result(i) = NaN;
    end

    Q_storage_used(i) = Q_discharge_to_load(i) / ETA_DIS;
    soc = max(0, min(SOC_MAX, Snext_now));

    % ---- 更新每台机组连续运行时长 ----
    for c = 1:N_CHILLER
        if x_now(c) == 1
            if x_prev(c) == 1
                runhour_prev(c) = runhour_prev(c) + 1;
            else
                runhour_prev(c) = 1;
            end
        else
            runhour_prev(c) = 0;
        end
    end
    x_prev = x_now;

    runhour1_result(i) = runhour_prev(1);
    runhour2_result(i) = runhour_prev(2);
    runhour3_result(i) = runhour_prev(3);

    % ---- 保存热启动信息 ----
    if USE_WARMSTART && solved_flag
        warm_x      = value(x);
        warm_u      = value(u);
        warm_lambda = value(lambda);
        warm_Qc     = value(Qc);
        warm_Pc     = value(Pc);
        warm_Qtotal = value(Qtotal);
        warm_Pch    = value(Pch);
        warm_Paux   = value(Paux);
        warm_Psys   = value(Psys);
        warm_Qdir   = value(Qdir);
        warm_Qch    = value(Qch);
        warm_Qdis   = value(Qdis);
        warm_Qunmet = value(Qunmet);
        warm_S      = value(S);
    elseif fallback_used(i)
        % 直供回退已经改变实际状态，旧的滚动计划不可再用作热启动。
        warm_Qtotal = [];
    end

    % ---- 运行模式标记 ----
    hasDir = Q_direct_to_load(i)    > 1e-6;
    hasCh  = Q_charge(i)            > 1e-6;
    hasDis = Q_discharge_to_load(i) > 1e-6;
    hasUm  = unmet_load(i)          > 1e-6;

    if hasDir && hasCh && hasDis
        mode_str(i) = "rolling_dir+charge+discharge_" + string(n_on_now) + "on";
    elseif hasDir && hasCh
        mode_str(i) = "rolling_dir+charge_" + string(n_on_now) + "on";
    elseif hasDir && hasDis
        mode_str(i) = "rolling_dir+discharge_" + string(n_on_now) + "on";
    elseif hasDir
        mode_str(i) = "rolling_dir_only_" + string(n_on_now) + "on";
    elseif hasCh
        mode_str(i) = "rolling_charge_only_" + string(n_on_now) + "on";
    elseif hasDis
        mode_str(i) = "rolling_discharge_only_" + string(n_on_now) + "on";
    else
        mode_str(i) = "rolling_idle";
    end

    if hasUm
        mode_str(i) = mode_str(i) + "_unmet";
    end
    if fallback_used(i)
        mode_str(i) = "fallback_direct_" + string(n_on_now) + "on";
    end

    % ---- SOC ----
    SOC_end(i) = soc;

    % ---- 总功率 ----
    P_aux_model(i)   = Paux_now;
    P_sys_model(i)   = Psys_now;
    P_total_model(i) = Psys_now;

    % ---- 本时刻电费 ----
    cost_case_hourly(i) = P_total_model(i) * DT * price_vec(i);

    % 热损失已在每小时SOC约束及回退计算中扣除；此处不可再次扣损失。
    roll_step_seconds(i) = toc(step_tic);
    if mod(i, PROGRESS_EVERY) == 0 || i == N
        report_idx = max(1, i - PROGRESS_EVERY + 1):i;
        try
            memory_stats = memory;
            roll_memory_mb(i) = memory_stats.MemUsedMATLAB / 1024^2;
        catch
            % memory 在部分平台或并行 worker 上不可用；耗时统计仍继续。
        end
        fprintf('[Case %d/%d] Steps %d-%d: %.2f s/step (model %.2f, optimize %.2f; YALMIP %.2f, solver %.2f), %d attempts, %d fallbacks, MATLAB %.0f MB\n', ...
            case_counter, total_cases, report_idx(1), i, ...
            mean(roll_step_seconds(report_idx)), mean(roll_model_seconds(report_idx)), ...
            mean(roll_optimize_seconds(report_idx)), mean(roll_yalmip_seconds(report_idx)), ...
            mean(roll_solver_seconds(report_idx)), sum(roll_attempt_count(report_idx)), ...
            sum(fallback_used(report_idx)), roll_memory_mb(i));
    end
end

%% =========================
% 10. 结果表
% =========================
fprintf('Case %d/%d rolling optimization complete in %.1f min; preparing results\n', ...
    case_counter, total_cases, toc(case_tic) / 60);
postprocess_tic = tic;
Result = table;
Result.scenario             = repmat(string(scenario_name), N, 1);
Result.storage_capacity_RT  = repmat(capacity_rt, N, 1);
Result.storage_capacity_kWh = repmat(SOC_MAX, N, 1);
Result.W_ENERGY             = repmat(W_ENERGY, N, 1);
Result.W_COST               = repmat(W_COST, N, 1);
Result.datetime             = dt;
Result.date                 = date_vec;
Result.month                = month_vec;
Result.hour                 = hour_vec;
Result.season               = season_str;
Result.mode                 = mode_str;
Result.T                    = T_out;
Result.Q_load               = Q_load;

Result.is_hot_day           = is_hot_day;
Result.price_vec            = price_vec;

Result.SOC_begin            = SOC_begin;
Result.SOC_end              = SOC_end;

Result.R_used               = R_used_result;

Result.x1_on                = x1_result;
Result.x2_on                = x2_result;
Result.x3_on                = x3_result;

Result.startup_total        = startup_total_result;
Result.startup1             = startup1_result;
Result.startup2             = startup2_result;
Result.startup3             = startup3_result;

Result.runhour1             = runhour1_result;
Result.runhour2             = runhour2_result;
Result.runhour3             = runhour3_result;

Result.n_on_result          = n_on_result;

Result.Q1                   = Q1_result;
Result.Q2                   = Q2_result;
Result.Q3                   = Q3_result;

Result.P1                   = P1_result;
Result.P2                   = P2_result;
Result.P3                   = P3_result;

Result.PLR1                 = PLR1_result;
Result.PLR2                 = PLR2_result;
Result.PLR3                 = PLR3_result;

Result.COP1                 = COP1_result;
Result.COP2                 = COP2_result;
Result.COP3                 = COP3_result;

Result.Q_single_avg         = Q_single_avg;
Result.PLR_single_avg       = PLR_single_avg;
Result.COP_single_avg       = COP_single_avg;
Result.P_single_avg         = P_single_avg;

Result.Q_total_chiller      = Q_total_chiller;
Result.PLR_total_chiller    = PLR_total_chiller;
Result.COP_total_chiller    = COP_total_chiller;
Result.P_total_chiller      = P_total_chiller;

Result.Q_direct_to_load     = Q_direct_to_load;
Result.Q_charge             = Q_charge;
Result.Q_discharge_to_load  = Q_discharge_to_load;
Result.Q_storage_used       = Q_storage_used;
Result.E_thermal_loss_kWh    = E_thermal_loss;
Result.unmet_load           = unmet_load;

Result.P_aux_model          = P_aux_model;
Result.P_sys_model          = P_sys_model;
Result.P_total_model        = P_total_model;
Result.cost_case_hourly     = cost_case_hourly;

Result.roll_window_obj      = roll_window_obj;
Result.roll_solve_problem   = roll_solve_problem;
Result.roll_solve_info      = roll_solve_info;
Result.roll_attempt_info    = roll_attempt_info;
Result.fallback_used        = fallback_used;
Result.fallback_note        = fallback_note;
Result.roll_step_seconds    = roll_step_seconds;
Result.roll_model_seconds   = roll_model_seconds;
Result.roll_optimize_seconds = roll_optimize_seconds;
Result.roll_yalmip_seconds  = roll_yalmip_seconds;
Result.roll_solver_seconds  = roll_solver_seconds;
Result.roll_attempt_count   = roll_attempt_count;
Result.roll_memory_mb       = roll_memory_mb;

%% =========================
% 11. 汇总表
% =========================
Summary_Item = {
    '全年总负荷(kWh)';
    '全年模型总能耗(kWh)';
    '全年冷机本体能耗(kWh)';
    '全年辅助设备能耗(kWh)';
    '辅助设备能耗占比';
    '全年总电费(元)';
    '全年冷机总供冷量(kWh)';
    '全年冷机直供负荷(kWh)';
    '全年蓄冷充冷量(kWh)';
    '全年蓄冷释冷量(kWh)';
    '全年蓄冷释冷对应的SOC扣减(kWh)';
    '全年未满足负荷(kWh)';
    '年末SOC(kWh)';
    '滚动优化失败并采用冷机直供的时数';
    '使用R=3小时数';
    '使用R=2小时数';
    '使用R=1小时数';
    '全年冷机启动总次数';
    '冷机1启动次数';
    '冷机2启动次数';
    '冷机3启动次数';
    '0台开机小时数';
    '1台开机小时数';
    '2台开机小时数';
    '3台开机小时数';
    '全年蓄冷环境热损失(kWh)';
    '储能全年能量平衡残差(kWh)';
};

Summary_Value = [
    sum(Q_load) * DT;
    sum(P_total_model) * DT;
    sum(P_total_chiller) * DT;
    sum(P_aux_model) * DT;
    sum(P_aux_model) * DT / max(sum(P_total_model) * DT, 1e-8);
    sum(cost_case_hourly);
    sum(Q_total_chiller) * DT;
    sum(Q_direct_to_load) * DT;
    sum(Q_charge) * DT;
    sum(Q_discharge_to_load) * DT;
    sum(Q_storage_used) * DT;
    sum(unmet_load) * DT;
    SOC_end(end);
    sum(fallback_used);
    sum(R_used_result == 3);
    sum(R_used_result == 2);
    sum(R_used_result == 1);
    sum(startup_total_result);
    sum(startup1_result);
    sum(startup2_result);
    sum(startup3_result);
    sum(n_on_result == 0);
    sum(n_on_result == 1);
    sum(n_on_result == 2);
    sum(n_on_result == 3);
    sum(E_thermal_loss);
    ETA_CH * sum(Q_charge) * DT - sum(Q_discharge_to_load) * DT / ETA_DIS ...
      - sum(E_thermal_loss) - SOC_end(end);
];

Summary = table(Summary_Item, Summary_Value);

CaseSummary = table( ...
    string(scenario_name), capacity_rt, SOC_MAX, W_ENERGY, W_COST, ...
    sum(Q_load) * DT, ...
    sum(P_total_model) * DT, ...
    sum(P_total_chiller) * DT, ...
    sum(P_aux_model) * DT, ...
    sum(cost_case_hourly), ...
    sum(Q_charge) * DT, ...
    sum(Q_discharge_to_load) * DT, ...
    sum(Q_storage_used) * DT, ...
    sum(unmet_load) * DT, ...
    sum(fallback_used), ...
    SOC_end(end), ...
    sum(startup_total_result), ...
    sum(R_used_result == 3), ...
    sum(R_used_result == 2), ...
    sum(R_used_result == 1), ...
    toc(case_tic), ...
    sum(E_thermal_loss), ...
    ETA_CH * sum(Q_charge) * DT - sum(Q_discharge_to_load) * DT / ETA_DIS ...
      - sum(E_thermal_loss) - SOC_end(end), ...
    'VariableNames', { ...
        'scenario', 'storage_capacity_RT', 'storage_capacity_kWh', 'W_ENERGY', 'W_COST', ...
        'total_load_kWh', 'total_energy_kWh', 'chiller_energy_kWh', 'aux_energy_kWh', ...
        'total_cost_yuan', 'charge_kWh', 'discharge_kWh', 'storage_used_kWh', ...
        'unmet_load_kWh', 'fallback_hours', 'final_SOC_kWh', 'startup_total', ...
        'R3_hours', 'R2_hours', 'R1_hours', 'case_seconds', ...
        'thermal_loss_kWh', 'storage_balance_residual_kWh'});

BatchSummaryCell{case_counter} = CaseSummary;

disp('================ 汇总结果 ================');
disp(Summary);

%% =========================
% 12. 逐日统计
% =========================
day_list = unique(date_vec);
nday = length(day_list);

daily_total_energy = zeros(nday, 1);
daily_total_cost   = zeros(nday, 1);
daily_charge       = zeros(nday, 1);
daily_discharge    = zeros(nday, 1);
daily_unmet        = zeros(nday, 1);
daily_soc_end      = zeros(nday, 1);

for d = 1:nday
    idx = (date_vec == day_list(d));

    daily_total_energy(d) = sum(P_total_model(idx)) * DT;
    daily_total_cost(d)   = sum(cost_case_hourly(idx));
    daily_charge(d)       = sum(Q_charge(idx)) * DT;
    daily_discharge(d)    = sum(Q_discharge_to_load(idx)) * DT;
    daily_unmet(d)        = sum(unmet_load(idx)) * DT;

    idx_last = find(idx, 1, 'last');
    daily_soc_end(d) = SOC_end(idx_last);
end

%% =========================
% 13. 绘图
% =========================
if MAKE_PLOTS
figure('Name', '全年SOC变化', 'Color', 'w');
plot(dt, SOC_end, 'b-', 'LineWidth', 1.0);
grid on;
xlabel('时间');
ylabel('SOC (kWh)');
title('全年SOC变化');

figure('Name', '逐日总电费', 'Color', 'w');
plot(day_list, daily_total_cost, 'r-', 'LineWidth', 1.2);
grid on;
xlabel('日期');
ylabel('日电费 (元)');
title('逐日总电费');

figure('Name', '逐日未满足负荷', 'Color', 'w');
bar(day_list, daily_unmet);
grid on;
xlabel('日期');
ylabel('未满足负荷 (kWh)');
title('逐日未满足负荷');

daily_load = zeros(nday, 1);
for d = 1:nday
    idx = (date_vec == day_list(d));
    daily_load(d) = sum(Q_load(idx)) * DT;
end

[~, id_peak] = max(daily_load);
peak_day = day_list(id_peak);
idx_peak = (date_vec == peak_day);

figure('Name', '典型日开机台数', 'Color', 'w');
stairs(dt(idx_peak), n_on_result(idx_peak), 'LineWidth', 1.5);
grid on;
xlabel('时间');
ylabel('开机台数');
ylim([-0.2, 3.2]);
title(['典型日开机台数：', datestr(peak_day)]);

figure('Name', '典型日三台机组开关状态', 'Color', 'w');
stairs(dt(idx_peak), [x1_result(idx_peak), x2_result(idx_peak), x3_result(idx_peak)], 'LineWidth', 1.2);
grid on;
xlabel('时间');
ylabel('开关状态');
ylim([-0.2, 1.2]);
legend('Chiller 1', 'Chiller 2', 'Chiller 3', 'Location', 'best');
title(['典型日三台机组开关状态：', datestr(peak_day)]);

figure('Name', '典型日R降级情况', 'Color', 'w');
stairs(dt(idx_peak), R_used_result(idx_peak), 'LineWidth', 1.5);
grid on;
xlabel('时间');
ylabel('求解成功时使用的R');
ylim([0.8, 3.2]);
title(['典型日R降级情况：', datestr(peak_day)]);
end

%% =========================
% 14. 导出
% =========================
fprintf('Case %d/%d result preparation took %.1f s; writing %s\n', ...
    case_counter, total_cases, toc(postprocess_tic), output_file);
export_tic = tic;
writetable(Result, output_file, 'Sheet', 'Hourly_Result');
writetable(Summary, output_file, 'Sheet', 'Summary');
writetable(CaseSummary, output_file, 'Sheet', 'Case_Summary');
FailureLog = Result(fallback_used, {'scenario', 'datetime', 'Q_load', ...
    'SOC_begin', 'roll_solve_problem', 'roll_attempt_info', 'fallback_note'});
if any(fallback_used)
    writetable(FailureLog, output_file, 'Sheet', 'Failure_Log');
end
fprintf('Case %d/%d Excel export took %.1f s\n', ...
    case_counter, total_cases, toc(export_tic));

fprintf('Case %d/%d finished: %s (%.1f min)\n', case_counter, total_cases, output_file, toc(case_tic) / 60);
drawnow;

end

BatchSummary = vertcat(BatchSummaryCell{:});
writetable(BatchSummary, 'batch_summary_all_cases_hourly_loss.xlsx', 'Sheet', 'Batch_Summary');
fprintf('\nAll cases finished. Batch summary saved to batch_summary_all_cases_hourly_loss.xlsx. Total elapsed %.1f min\n', toc(batch_tic) / 60);
drawnow;


%% =========================
% 15. 函数：直供回退、COP
% =========================
function [x_now, Qc_now, Pc_now, note] = direct_fallback_dispatch( ...
        load_now, x_prev, runhour_prev, R_init, n_chiller, ...
        q_rated, plr_min, plr_max, q_break, p_break)
    q_min = q_rated * plr_min;
    q_max = q_rated * plr_max;
    feasible_n = find(load_now >= (1:n_chiller) * q_min - 1e-6 ...
        & load_now <= (1:n_chiller) * q_max + 1e-6);
    if isempty(feasible_n)
        error(['Direct fallback cannot meet load %.6g kW within %d chillers ', ...
            'and PLR range [%.3g, %.3g].'], ...
            load_now, n_chiller, plr_min, plr_max);
    end

    % 尽可能保持已有机组的最短连续运行要求。
    must_keep = find(x_prev == 1 & runhour_prev < R_init, 1, 'last');
    if isempty(must_keep)
        must_keep = 0;
    end
    eligible = feasible_n(feasible_n >= must_keep);
    if isempty(eligible)
        n_on = feasible_n(1);
        note = "Direct supply met load; minimum run time relaxed";
    else
        n_on = eligible(1);
        note = "Direct supply met load";
    end

    x_now = [ones(1, n_on), zeros(1, n_chiller - n_on)];
    Qc_now = zeros(1, n_chiller);
    Pc_now = zeros(1, n_chiller);
    Qc_now(1:n_on) = load_now / n_on;
    Pc_now(1:n_on) = interp1(q_break, p_break, ...
        Qc_now(1:n_on), 'linear');
end

function print_parallel_progress(msg, total_cases, N, batch_tic)
    persistent reported_steps
    if isempty(reported_steps) || numel(reported_steps) ~= total_cases
        reported_steps = zeros(total_cases, 1);
    end

    reported_steps(msg.case_id) = max(reported_steps(msg.case_id), msg.step);

    batch_done_steps = sum(reported_steps);
    batch_total_steps = total_cases * N;
    batch_elapsed = toc(batch_tic);
    batch_eta = batch_elapsed / max(batch_done_steps, 1) * max(batch_total_steps - batch_done_steps, 0);

    fprintf('[%s | Case %d/%d] Rolling step %d/%d (%.1f%%), case elapsed %.1f min, case ETA %.1f min, batch %.1f%%, batch ETA %.1f min\n', ...
        datestr(now, 'yyyy-mm-dd HH:MM:SS'), msg.case_id, total_cases, msg.step, N, ...
        100 * msg.step / N, msg.case_elapsed / 60, msg.case_eta / 60, ...
        100 * batch_done_steps / batch_total_steps, batch_eta / 60);
    drawnow;
end

function COP = cop_func(T, PLR)
    CEFT=T;
    COP = 21.7063 ...
        + 1.9054   .* PLR ...
        - 10.8474   .* PLR.^2 ...
        + 0.3610   .* PLR.^3 ...
        - 1.5065   .* CEFT ...
        + 0.0361   .* CEFT.^2 ...
        - 0.00025  .* CEFT.^3 ...
        + 0.5814   .* PLR .* CEFT ...
        + 0.2342   .* PLR.^2 .* CEFT ...
        - 0.0156   .* PLR .* CEFT.^2;
end
%% =========================
% 16. 峰谷电价函数
% month   : 1~12
% hour    : 0~23
% isHotDay: 是否高温天（逻辑值）
% 返回    : 元/kWh
% =========================
function price = get_tou_price(month, hour, isHotDay)

    h = hour + 1;

    switch month
        case 1
            p_nonhot = [ ...
                0.2659 0.2659 0.2659 0.2659 0.2659 0.2659 0.2659 0.2659 ...
                0.6546 0.6546 1.0934 1.0934 0.6546 0.6546 1.0934 1.0934 ...
                1.0934 1.0934 1.0934 0.6546 0.6546 0.6546 0.6546 0.6546];
            price = p_nonhot(h);

        case 2
            p_nonhot = [ ...
                0.2702 0.2702 0.2702 0.2702 0.2702 0.2702 0.2702 0.2702 ...
                0.6659 0.6659 1.1126 1.1126 0.6659 0.6659 1.1126 1.1126 ...
                1.1126 1.1126 1.1126 0.6659 0.6659 0.6659 0.6659 0.6659];
            price = p_nonhot(h);

        case 3
            p_nonhot = [ ...
                0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 ...
                0.6600 0.6600 1.1025 1.1025 0.6600 0.6600 1.1025 1.1025 ...
                1.1025 1.1025 1.1025 0.6600 0.6600 0.6600 0.6600 0.6600];
            price = p_nonhot(h);

        case 4
            p_nonhot = [ ...
                0.2612 0.2612 0.2612 0.2612 0.2612 0.2612 0.2612 0.2612 ...
                0.6423 0.6423 1.0725 1.0725 0.6423 0.6423 1.0725 1.0725 ...
                1.0725 1.0725 1.0725 0.6423 0.6423 0.6423 0.6423 0.6423];
            p_hot = [ ...
                0.2612 0.2612 0.2612 0.2612 0.2612 0.2612 0.2612 0.2612 ...
                0.6423 0.6423 1.0725 1.3337 0.6423 0.6423 1.0725 1.3337 ...
                1.3337 1.0725 1.0725 0.6423 0.6423 0.6423 0.6423 0.6423];
            if isHotDay
                price = p_hot(h);
            else
                price = p_nonhot(h);
            end

        case 5
            p_nonhot = [ ...
                0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 ...
                0.6600 0.6600 1.1025 1.1025 0.6600 0.6600 1.1025 1.1025 ...
                1.1025 1.1025 1.1025 0.6600 0.6600 0.6600 0.6600 0.6600];
            p_hot = [ ...
                0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 0.2680 ...
                0.6600 0.6600 1.1025 1.3712 0.6600 0.6600 1.1025 1.3712 ...
                1.3712 1.1025 1.1025 0.6600 0.6600 0.6600 0.6600 0.6600];
            if isHotDay
                price = p_hot(h);
            else
                price = p_nonhot(h);
            end

        case 6
            p_nonhot = [ ...
                0.2586 0.2586 0.2586 0.2586 0.2586 0.2586 0.2586 0.2586 ...
                0.6352 0.6352 1.0604 1.0604 0.6352 0.6352 1.0604 1.0604 ...
                1.0604 1.0604 1.0604 0.6352 0.6352 0.6352 0.6352 0.6352];
            p_hot = [ ...
                0.2586 0.2586 0.2586 0.2586 0.2586 0.2586 0.2586 0.2586 ...
                0.6352 0.6352 1.0604 1.3185 0.6352 0.6352 1.0604 1.3185 ...
                1.3185 1.0604 1.0604 0.6352 0.6352 0.6352 0.6352 0.6352];
            if isHotDay
                price = p_hot(h);
            else
                price = p_nonhot(h);
            end

        case 7
            p_hot = [ ...
                0.2510 0.2510 0.2510 0.2510 0.2510 0.2510 0.2510 0.2510 ...
                0.6154 0.6154 1.0268 1.2766 0.6154 0.6154 1.0268 1.2766 ...
                1.2766 1.0268 1.0268 0.6154 0.6154 0.6154 0.6154 0.6154];
            price = p_hot(h);

        case 8
            p_hot = [ ...
                0.2600 0.2600 0.2600 0.2600 0.2600 0.2600 0.2600 0.2600 ...
                0.6392 0.6392 1.0672 1.3271 0.6392 0.6392 1.0672 1.3271 ...
                1.3271 1.0672 1.0672 0.6392 0.6392 0.6392 0.6392 0.6392];
            price = p_hot(h);

        case 9
            p_hot = [ ...
                0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 ...
                0.6542 0.6542 1.0927 1.3590 0.6542 0.6542 1.0927 1.3590 ...
                1.3590 1.0927 1.0927 0.6542 0.6542 0.6542 0.6542 0.6542];
            price = p_hot(h);

        case 10
            p_nonhot = [ ...
                0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 ...
                0.6540 0.6540 1.0924 1.0924 0.6540 0.6540 1.0924 1.0924 ...
                1.0924 1.0924 1.0924 0.6540 0.6540 0.6540 0.6540 0.6540];
            p_hot = [ ...
                0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 0.2657 ...
                0.6540 0.6540 1.0924 1.3586 0.6540 0.6540 1.0924 1.3586 ...
                1.3586 1.0924 1.0924 0.6540 0.6540 0.6540 0.6540 0.6540];
            if isHotDay
                price = p_hot(h);
            else
                price = p_nonhot(h);
            end

        case 11
            p_nonhot = [ ...
                0.2570 0.2570 0.2570 0.2570 0.2570 0.2570 0.2570 0.2570 ...
                0.6312 0.6312 1.0536 1.0536 0.6312 0.6312 1.0536 1.0536 ...
                1.0536 1.0536 1.0536 0.6312 0.6312 0.6312 0.6312 0.6312];
            p_hot = [ ...
                0.2570 0.2570 0.2570 0.2570 0.2570 0.2570 0.2570 0.2570 ...
                0.6312 0.6312 1.0536 1.3101 0.6312 0.6312 1.0536 1.3101 ...
                1.3101 1.0536 1.0536 0.6312 0.6312 0.6312 0.6312 0.6312];
            if isHotDay
                price = p_hot(h);
            else
                price = p_nonhot(h);
            end

        case 12
            p_nonhot = [ ...
                0.2624 0.2624 0.2624 0.2624 0.2624 0.2624 0.2624 0.2624 ...
                0.6453 0.6453 1.0776 1.0776 0.6453 0.6453 1.0776 1.0776 ...
                1.0776 1.0776 1.0776 0.6453 0.6453 0.6453 0.6453 0.6453];
            price = p_nonhot(h);

        otherwise
            error('月份输入错误，应为 1~12');
    end
end


function safe_yalmip_clear()
    yalmip('clear');
end
