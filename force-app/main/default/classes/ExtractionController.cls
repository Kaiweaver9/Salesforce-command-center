public with sharing class ExtractionController {

    /* --- DASHBOARD LOGIC --- */
    @AuraEnabled
    public static Map<String, Object> getDashboardData() {
        Map<String, Object> data = new Map<String, Object>();
        try {
            List<Performance_Index__c> latestIndex = [SELECT Total_Index__c FROM Performance_Index__c ORDER BY Performance_Date__c DESC, CreatedDate DESC LIMIT 1];
            data.put('upiTotal', !latestIndex.isEmpty() ? latestIndex[0].Total_Index__c.setScale(0) : 0);

            // 1. CHASE BALANCE
            AggregateResult[] finResults = [SELECT SUM(Transaction_Amount__c) total 
                                            FROM financial_data__c 
                                            WHERE Transaction_Date__c <= TODAY];
            Decimal currentBalance = (Decimal)finResults[0].get('total') != null ? (Decimal)finResults[0].get('total') : 0.00;
            data.put('currentBalance', currentBalance);

            // 2. NET WORTH MULTI-ACCOUNT AGGREGATION
            AggregateResult[] netWorthResults = [SELECT SUM(Current_Value__c) total FROM Financial_Account__c];
            Decimal netWorth = (Decimal)netWorthResults[0].get('total') != null ? (Decimal)netWorthResults[0].get('total') : 0.00;
            data.put('netWorth', netWorth);

            Date realToday = Date.today();
            Date startOfMonth = realToday.toStartOfMonth();
            AggregateResult[] somResults = [SELECT SUM(Transaction_Amount__c) total FROM financial_data__c WHERE Transaction_Date__c < :startOfMonth];
            Decimal balanceAtStart = (Decimal)somResults[0].get('total') != null ? (Decimal)somResults[0].get('total') : 0.00;
            
            data.put('finTrend', currentBalance == balanceAtStart ? 'PLATEAU' : (currentBalance > balanceAtStart ? 'OPTIMAL' : 'DECAY'));

            List<Goal_Setting__c> activeGoals = [SELECT Id, Name, Goal_Type__c, Goal_Target__c, Goal_Start__c, Goal_Start_Date__c, Target_Reached_Date__c, current_phase__c 
                                                 FROM Goal_Setting__c 
                                                 WHERE Display_on_Command_Center__c = true];
            Id carGoalId = null;
            Decimal weightTarget = 0.0;
            Goal_Setting__c weightGoalRecord = null; 
            Decimal financialTarget = 0.0;
            Boolean triggerPhaseUpdate = false;

            for(Goal_Setting__c g : activeGoals) {
                if(g.Goal_Type__c == 'Financial') {
                    carGoalId = g.Id;
                    financialTarget = g.Goal_Target__c != null ? g.Goal_Target__c : 7000.0;
                    data.put('finTarget', financialTarget);
                    data.put('finLabel', g.Name.toUpperCase());
                } else if(g.Goal_Type__c == 'Health') { 
                    weightGoalRecord = g;
                    weightTarget = g.Goal_Target__c;
                    data.put('goalLabel', g.Name.toUpperCase());
                    data.put('goalTarget', weightTarget);
                    data.put('goalStart', g.Goal_Start__c != null ? g.Goal_Start__c : 0.0);
                    
                    Date phaseAnchor = g.Target_Reached_Date__c != null ? g.Target_Reached_Date__c : g.Goal_Start_Date__c;
                    if (g.current_phase__c != null && g.current_phase__c.equalsIgnoreCase('reverse') && phaseAnchor != null) {
                        if (phaseAnchor.daysBetween(realToday) > 42) {
                            g.current_phase__c = 'Bulking';
                            triggerPhaseUpdate = true;
                        }
                    }
                    data.put('currentPhase', g.current_phase__c != null ? g.current_phase__c.toLowerCase() : 'maintenance');
                }
            }

            if (triggerPhaseUpdate && weightGoalRecord != null) {
                update weightGoalRecord;
            }

            // --- BIOMECHANICAL ANALYTICS ---
            Date thresholdDate = Date.today().addDays(-21);
            
            List<Health_Data__c> healthLogs = [SELECT Weight_lbs__c, Calories__c, Entry_Date__c, Protein_g__c, Carbs_g__c, Fat_g__c, TDEE__c, Body_Fat__c 
                                               FROM Health_Data__c 
                                               WHERE Calories__c != null AND Weight_lbs__c != null 
                                               AND Entry_Date__c >= :thresholdDate
                                               ORDER BY Entry_Date__c DESC LIMIT 15];
            
            if(!healthLogs.isEmpty()){
                Health_Data__c latest = healthLogs[0];
                data.put('currentWeight', latest.Weight_lbs__c);
                data.put('lastWeighInDate', String.valueOf(latest.Entry_Date__c));
                data.put('calories', latest.Calories__c);
                data.put('protein', latest.Protein_g__c != null ? latest.Protein_g__c : 0);
                data.put('carbs', latest.Carbs_g__c != null ? latest.Carbs_g__c : 0);
                data.put('fat', latest.Fat_g__c != null ? latest.Fat_g__c : 0);

                if(healthLogs.size() >= 2) {
                    Health_Data__c previous = healthLogs[1];
                    data.put('weightTrend', latest.Weight_lbs__c == previous.Weight_lbs__c ? 'PLATEAU' : (latest.Weight_lbs__c > previous.Weight_lbs__c ? 'DECAY' : 'OPTIMAL'));
                }

                Decimal dailySlope = 0.0;
                if(healthLogs.size() >= 3) {
                    List<Health_Data__c> chronoHistory = new List<Health_Data__c>();
                    for(Integer i = healthLogs.size() - 1; i >= 0; i--) { chronoHistory.add(healthLogs[i]); }
                    dailySlope = calculateWeightSlope(chronoHistory);
                } else if(healthLogs.size() == 2) {
                    Integer days = healthLogs[1].Entry_Date__c.daysBetween(healthLogs[0].Entry_Date__c);
                    Decimal span = (days <= 0) ? 1.0 : Decimal.valueOf(days);
                    dailySlope = (healthLogs[0].Weight_lbs__c - healthLogs[1].Weight_lbs__c) / span;
                }
                
                Decimal weeklyVelocity = dailySlope * 7.0;
                data.put('weeklyVelocity', weeklyVelocity.setScale(2));

                Integer tdee = (latest.TDEE__c != null) ? Math.round(latest.TDEE__c) : 2500; 
                data.put('rollingTDEE', tdee);

                String status = 'OPTIMAL';
                String statusColor = 'biomech-green';
                Boolean isCutting = (weightTarget > 0 && latest.Weight_lbs__c > weightTarget);
                String currentPhaseStr = (String)data.get('currentPhase');

                // --- LAMBDA STEERING LOGIC INTEGRATION ---
                Decimal lambda = calculateLambda(healthLogs);
                data.put('lambdaConfidence', lambda.setScale(2));

                // --- STEERING LOGIC INTEGRATION ---
                if(isCutting && currentPhaseStr == 'cutting') {
                    data.put('recommendedCalories', Math.round(tdee * 0.80));
                    Decimal absV = weeklyVelocity.abs();
                    if(weeklyVelocity > 0) { status = 'STALLED'; statusColor = 'neutral-gray'; }
                    else if(absV <= 2.0) { status = 'OPTIMAL'; statusColor = 'biomech-green'; }
                    else if(absV <= 2.5) { status = 'PERFECT'; statusColor = 'status-perfect'; }
                    else if(absV <= 3.0) { status = 'WARNING'; statusColor = 'warning-amber'; }
                    else { status = 'DANGER'; statusColor = 'breach-red'; }
                } 
                else if(currentPhaseStr == 'reverse' && weightGoalRecord != null) {
                    status = 'RECOVERY';
                    statusColor = 'biomech-green';
                    Date reverseAnchorDate = weightGoalRecord.Target_Reached_Date__c != null ? weightGoalRecord.Target_Reached_Date__c : weightGoalRecord.Goal_Start_Date__c;
                    Integer daysSinceExtraction = (reverseAnchorDate != null) ? reverseAnchorDate.daysBetween(realToday) : 0;
                    Decimal dynamicTDEE = (latest.TDEE__c != null) ? latest.TDEE__c : tdee; 
                    Decimal calorieFloor = dynamicTDEE * 0.85;
                    
                    if(daysSinceExtraction < 7) data.put('recommendedCalories', Math.round(calorieFloor));
                    else if(daysSinceExtraction < 14) data.put('recommendedCalories', Math.round(calorieFloor + 150));
                    else if(daysSinceExtraction < 21) data.put('recommendedCalories', Math.round(calorieFloor + 300));
                    else data.put('recommendedCalories', Math.round(dynamicTDEE));
                }
                else if(currentPhaseStr == 'bulking' || currentPhaseStr == 'maintenance') {
                    Decimal targetV = (currentPhaseStr == 'bulking') ? 0.2 : 0.0;
                    Decimal velocityError = weeklyVelocity - targetV;
                    
                    // Asymmetric Override: Unrestricted fueling when falling behind the curve
                    Decimal appliedLambda = lambda;
                    if (currentPhaseStr == 'bulking' && velocityError < 0) {
                        appliedLambda = 1.0; 
                    }

                    Decimal steeringAdjustment = (velocityError * 500) * appliedLambda; 
                    Decimal calorieBase = (currentPhaseStr == 'bulking') ? tdee + 100 : tdee;
                    
                    data.put('recommendedCalories', Math.round(calorieBase - steeringAdjustment));

                    if(currentPhaseStr == 'bulking') {
                        if(weeklyVelocity <= 0.09) { status = 'STALLED'; statusColor = 'neutral-gray'; } 
                        else if(weeklyVelocity >= 0.18 && weeklyVelocity <= 0.22) { status = 'PERFECT'; statusColor = 'status-perfect'; } 
                        else if(weeklyVelocity <= 0.50) { status = 'OPTIMAL'; statusColor = 'biomech-green'; } 
                        else if(weeklyVelocity <= 0.75) { status = 'CAUTION'; statusColor = 'kinetic-lime'; } 
                        else if(weeklyVelocity <= 1.00) { status = 'WARNING'; statusColor = 'warning-amber'; } 
                        else { status = 'DANGER'; statusColor = 'breach-red'; }
                    }
                }
                else { data.put('recommendedCalories', Math.round(tdee)); }

                data.put('clinicalStatus', status);
                data.put('statusColor', statusColor);
                
                if(weightTarget > 0 && weightTarget != latest.Weight_lbs__c && dailySlope != 0) {
                    Boolean validDirection = ((isCutting || currentPhaseStr == 'cutting') && dailySlope < 0) || (currentPhaseStr == 'bulking' && dailySlope > 0);
                    if(validDirection) {
                        Decimal absDailyRate = dailySlope.abs();
                        Integer daysFromLogToGoal = (Integer)((latest.Weight_lbs__c - weightTarget).abs() / absDailyRate);
                        Date projectedDate = latest.Entry_Date__c.addDays(daysFromLogToGoal);
                        Integer trueDaysRemaining = realToday.daysBetween(projectedDate);
                        if(trueDaysRemaining < 0) trueDaysRemaining = 0;
                        data.put('weightDaysRemaining', String.valueOf(trueDaysRemaining));
                        data.put('weightProjectedDate', String.valueOf(projectedDate)); 
                    } else {
                        data.put('weightDaysRemaining', 'STALLED');
                    }
                } else {
                    data.put('weightDaysRemaining', 'STALLED');
                }
            }

            // --- INTEGRATED EXTRACTION ENGINE ---
            List<Budget_Category__c> budgets = [SELECT Monthly_Allocation__c, Actual_Spent__c, Day_of_Month__c, Frequency__c FROM Budget_Category__c WHERE Monthly_Allocation__c > 0];
            List<Pay_Period__c> pay = [SELECT Net_Extraction__c, Pay_Date__c FROM Pay_Period__c WHERE associated_goal__c = :carGoalId AND Status__c = 'Projected' AND Pay_Date__c >= TODAY ORDER BY Pay_Date__c ASC];

            Decimal simBal = currentBalance;
            Integer fDays = 0;
            Date sDate = realToday;

            while (simBal < financialTarget && fDays < 730) {
                fDays++; sDate = sDate.addDays(1); 
                for (Integer i = pay.size() - 1; i >= 0; i--) { if (pay[i].Pay_Date__c == sDate) { simBal += pay[i].Net_Extraction__c; pay.remove(i); } }
                for (Budget_Category__c bc : budgets) {
                    Integer billDay = (bc.Day_of_Month__c != null) ? Integer.valueOf(bc.Day_of_Month__c) : null;
                    if (bc.Frequency__c == 'Every month' && billDay != null) {
                        if (sDate.month() == realToday.month() && sDate.year() == realToday.year()) {
                            Decimal remaining = bc.Monthly_Allocation__c - (bc.Actual_Spent__c != null ? bc.Actual_Spent__c : 0);
                            if (sDate.day() == billDay && remaining > 0) simBal -= remaining;
                        } else if (sDate.day() == billDay) simBal -= bc.Monthly_Allocation__c;
                    } else simBal -= (bc.Monthly_Allocation__c / 30.44);
                }
            }
            data.put('finDaysRemaining', String.valueOf(fDays));
            data.put('totalTrailheadPoints', [SELECT SUM(Points_Gained__c) total FROM Trailhead_Log__c][0].get('total'));

            List<String> labels = new List<String>();
            List<Decimal> finHistory = new List<Decimal>();
            List<Decimal> healthHistory = new List<Decimal>();

            for(Performance_Index__c pi : [SELECT Performance_Date__c, Financial_Index__c, Health_Index__c FROM Performance_Index__c WHERE Performance_Date__c != null ORDER BY Performance_Date__c DESC LIMIT 14]) {
                labels.add(pi.Performance_Date__c.month() + '/' + pi.Performance_Date__c.day());
                finHistory.add(pi.Financial_Index__c != null ? pi.Financial_Index__c : 0);
                healthHistory.add(pi.Health_Index__c != null ? pi.Health_Index__c : 0);
            }
            data.put('indexLabels', labels);
            data.put('finIndexHistory', finHistory);
            data.put('healthIndexHistory', healthHistory);

        } catch (Exception e) { System.debug('Extraction Error: ' + e.getMessage()); }
        return data;
    }

    /* --- ANALYTICS ENGINE: STATISTICAL AGGREGATION --- */
    @AuraEnabled
    public static Map<String, String> getMetricStats(String node, String metric, String timeframe) {
        Map<String, String> stats = new Map<String, String>();
        Date startDate = Date.today();
        
        if (timeframe == '7D') startDate = startDate.addDays(-7);
        else if (timeframe == '30D') startDate = startDate.addDays(-30);
        else startDate = Date.newInstance(startDate.year(), 1, 1);

        String obj = (node == 'HEALTH') ? 'Health_Data__c' : 'financial_data__c';
        String dateField = (node == 'HEALTH') ? 'Entry_Date__c' : 'Transaction_Date__c';
        String field = getFieldNameMapping(metric);

        String query = 'SELECT AVG(' + field + ') avgVal, MIN(' + field + ') minVal, MAX(' + field + ') maxVal FROM ' + obj + 
                       ' WHERE ' + dateField + ' >= :startDate AND ' + field + ' != null';

        List<AggregateResult> records = Database.query(query);
        if (records.isEmpty() || records[0].get('avgVal') == null) return new Map<String, String>{'avg'=>'—','min'=>'—','max'=>'—'};

        Decimal avgVal = (Decimal)records[0].get('avgVal');
        Decimal minVal = (Decimal)records[0].get('minVal');
        Decimal maxVal = (Decimal)records[0].get('maxVal');
        
        Integer precision = (metric == 'CALORIES' || metric == 'TDEE') ? 0 : 1;
        String unit = (metric == 'WEIGHT') ? ' lbs' : (metric == 'CALORIES' || metric == 'TDEE' ? ' kcal' : (metric == 'BODY FAT' ? '%' : 'g'));
        if(node == 'FINANCIAL') unit = ''; 

        stats.put('avg', (node == 'FINANCIAL' ? '$' + avgVal.setScale(2).format() : avgVal.setScale(precision).format() + unit));
        stats.put('min', (node == 'FINANCIAL' ? '$' + minVal.setScale(2).format() : minVal.setScale(precision).format() + unit));
        stats.put('max', (node == 'FINANCIAL' ? '$' + maxVal.setScale(2).format() : maxVal.setScale(precision).format() + unit));

        return stats;
    }

    private static String getFieldNameMapping(String metric) {
        Map<String, String> m = new Map<String, String>{
            'WEIGHT' => 'Weight_lbs__c', 'TDEE' => 'TDEE__c', 'CALORIES' => 'Calories__c',
            'PROTEIN' => 'Protein_g__c', 'CARBS' => 'Carbs_g__c', 'FAT' => 'Fat_g__c',
            'BODY FAT' => 'Body_Fat__c', 'CASH_FLOW' => 'Transaction_Amount__c'
        };
        return m.get(metric);
    }

    /* --- DYNAMIC ANALYTICS ENGINE (Infrastructure Node) --- */
    @AuraEnabled
    public static List<Map<String, Object>> getUnifiedHistory(String node, String fieldName, Integer days) {
        List<Map<String, Object>> dataPoints = new List<Map<String, Object>>();
        try {
            Date startDate = Date.today().addDays(-days);
            String obj = (node == 'HEALTH') ? 'Health_Data__c' : 'financial_data__c';
            String dateField = (node == 'HEALTH') ? 'Entry_Date__c' : 'Transaction_Date__c';
            
            String query = 'SELECT ' + String.escapeSingleQuotes(fieldName) + ', ' + dateField + 
                           ' FROM ' + obj + 
                           ' WHERE ' + dateField + ' >= :startDate AND ' + String.escapeSingleQuotes(fieldName) + ' != null ' +
                           ' ORDER BY ' + dateField + ' ASC';
            
            for (SObject record : Database.query(query)) {
                dataPoints.add(new Map<String, Object>{
                    'val' => record.get(fieldName),
                    'day' => record.get(dateField)
                });
            }
        } catch (Exception e) { System.debug('Dynamic Query Error: ' + e.getMessage()); }
        return dataPoints;
    }

    /**
     * STAMPTDEE - REFACTORED WITH DUAL-REGRESSION COMPOSITION TRACKING & NULL GUARDS
     */
    public static void stampTDEE(List<Health_Data__c> logsToStamp) {
        if(logsToStamp == null || logsToStamp.isEmpty()) return;
        
        Date minDate = logsToStamp[0].Entry_Date__c.addDays(-21);
        Date maxDate = logsToStamp[logsToStamp.size()-1].Entry_Date__c;
        
        List<Health_Data__c> relevantHistory = [SELECT Weight_lbs__c, Calories__c, Entry_Date__c, Body_Fat__c 
                                                FROM Health_Data__c 
                                                WHERE Entry_Date__c >= :minDate 
                                                AND Entry_Date__c <= :maxDate 
                                                AND Weight_lbs__c != null 
                                                ORDER BY Entry_Date__c ASC];

        for(Health_Data__c log : logsToStamp) {
            if(log.TDEE__c != null) continue; 
            if(log.Calories__c == null || log.Weight_lbs__c == null || log.Entry_Date__c == null) continue;
            
            if(log.Body_Fat__c != null) {
                log.Fat_Mass__c = (log.Weight_lbs__c * (log.Body_Fat__c / 100.0)).setScale(1);
                log.Lean_Body_Mass__c = (log.Weight_lbs__c - log.Fat_Mass__c).setScale(1);
            }
            
            Date lookback = log.Entry_Date__c.addDays(-14);
            List<Health_Data__c> window = new List<Health_Data__c>();
            Decimal totalCals = 0;
            
            for(Health_Data__c h : relevantHistory) { 
                if(h.Entry_Date__c >= lookback && h.Entry_Date__c <= log.Entry_Date__c) { 
                    window.add(h); 
                    totalCals += (h.Calories__c != null ? h.Calories__c : 0); 
                } 
            }

            if(window.size() >= 3) {
                Decimal avgDailyCals = totalCals / window.size();
                Decimal tissueEnergySlope = calculateTissueFluxSlope(window);
                if (tissueEnergySlope != null) {
                    log.TDEE__c = Math.round(avgDailyCals - tissueEnergySlope);
                } else {
                    Decimal slope = calculateWeightSlope(window);
                    log.TDEE__c = Math.round(avgDailyCals - (slope * 3500.0));
                }
            }
        }
    }

    private static Decimal calculateLambda(List<Health_Data__c> logs) {
        if (logs.size() < 3) return 1.0;
        Decimal fatDelta = (logs[0].Weight_lbs__c * (logs[0].Body_Fat__c / 100.0)) - (logs[logs.size()-1].Weight_lbs__c * (logs[logs.size()-1].Body_Fat__c / 100.0));
        Decimal weightDelta = logs[0].Weight_lbs__c - logs[logs.size()-1].Weight_lbs__c;
        if (weightDelta == 0) return 0.5;
        Decimal compositionRatio = (weightDelta > 0) ? (fatDelta / weightDelta) : (weightDelta / fatDelta);
        
        return Math.max(0.1, Math.min(1.0, compositionRatio.setScale(2)));
    }
    private static Decimal calculateWeightSlope(List<Health_Data__c> history) {
        if (history == null || history.isEmpty()) return 0.0;
        List<Health_Data__c> validHistory = new List<Health_Data__c>();
        for (Health_Data__c log : history) {
            if (log.Entry_Date__c != null && log.Weight_lbs__c != null) {
                validHistory.add(log);
            }
        }
        Integer n = validHistory.size();
        if (n < 2) return 0.0;
        Decimal sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
        Date firstDate = validHistory[0].Entry_Date__c;
        for (Health_Data__c log : validHistory) {
            Decimal x = firstDate.daysBetween(log.Entry_Date__c);
            Decimal y = log.Weight_lbs__c;
            sumX += x; sumY += y; sumXY += (x * y); sumX2 += (x * x);
        }
        Decimal divisor = (n * sumX2 - (sumX * sumX));
        if (divisor == 0) return 0.0;
        return (n * sumXY - (sumX * sumY)) / divisor;
    }

    private static Decimal calculateTissueFluxSlope(List<Health_Data__c> window) {
        if(window == null || window.isEmpty()) return null;
        Date baseDate = window[0].Entry_Date__c;
        Integer n = 0;
        Decimal sumX = 0, sumFatY = 0, sumLeanY = 0, sumXFatY = 0, sumXLeanY = 0, sumXX = 0;
        for(Health_Data__c h : window) {
            if(h.Body_Fat__c == null || h.Weight_lbs__c == null || h.Entry_Date__c == null) continue;
            Decimal x = baseDate.daysBetween(h.Entry_Date__c);
            Decimal fatMass = h.Weight_lbs__c * (h.Body_Fat__c / 100.0);
            Decimal leanMass = h.Weight_lbs__c - fatMass;
            sumX += x; sumFatY += fatMass; sumLeanY += leanMass; sumXFatY += (x * fatMass); sumXLeanY += (x * leanMass); sumXX += (x * x);
            n++;
        }
        if(n < 3) return null; 
        Decimal denominator = (n * sumXX) - (sumX * sumX);
        if(denominator == 0) return null;
        Decimal fatSlope = ((n * sumXFatY) - (sumX * sumFatY)) / denominator;  
        Decimal leanSlope = ((n * sumXLeanY) - (sumX * sumLeanY)) / denominator; 
        return (fatSlope * 3500.0) + (leanSlope * 1200.0); 
    }

    @InvocableMethod(label='Calculate Sovereign Performance Indices' category='Sovereign')
    public static List<PerformanceOutput> calculatePerformanceIndices(List<PerformanceInput> inputs) {
        List<PerformanceOutput> outputs = new List<PerformanceOutput>();
        for(PerformanceInput input : inputs) {
            PerformanceOutput res = new PerformanceOutput();
            Date anchorDate = input.currentDate;
            Date windowStart = anchorDate.addDays(-31);
            AggregateResult[] incomeResults = [SELECT SUM(Transaction_Amount__c) total FROM financial_data__c WHERE Transaction_Type__c = 'Income' AND Transaction_Date__c >= :windowStart AND Transaction_Date__c <= :anchorDate];
            Decimal totalIncome = (Decimal)incomeResults[0].get('total') != null ? (Decimal)incomeResults[0].get('total') : 0.0;
            Decimal actualDailyVelocity = totalIncome / 30.0;
            List<Pay_Period__c> activePP = [SELECT Base_Extraction__c FROM Pay_Period__c WHERE Pay_Date__c >= :anchorDate ORDER BY Pay_Date__c ASC LIMIT 1];
            Decimal targetDailyVelocity = 1.0; 
            if (!activePP.isEmpty() && activePP[0].Base_Extraction__c != null) { targetDailyVelocity = activePP[0].Base_Extraction__c / 14.0; }
            res.financialIndex = (targetDailyVelocity > 0) ? (actualDailyVelocity / targetDailyVelocity) * 100 : 0;
            
            List<Goal_Setting__c> healthGoals = [SELECT Goal_Target__c, Goal_Start_Date__c, Target_Reached_Date__c, current_phase__c FROM Goal_Setting__c WHERE Goal_Type__c = 'Health' AND Display_on_Command_Center__c = true LIMIT 1];
            List<Health_Data__c> logs = [SELECT Weight_lbs__c, Calories__c, TDEE__c, Entry_Date__c FROM Health_Data__c WHERE Entry_Date__c <= :anchorDate ORDER BY Entry_Date__c DESC LIMIT 15];
            
            if(logs.isEmpty() || healthGoals.isEmpty()) { 
                res.healthIndex = 100; 
            } else {
                Health_Data__c latestLog = logs[0];
                Decimal weightTarget = healthGoals[0].Goal_Target__c != null ? healthGoals[0].Goal_Target__c : 0.0;
                Date anchorDateGoal = healthGoals[0].Target_Reached_Date__c != null ? healthGoals[0].Target_Reached_Date__c : healthGoals[0].Goal_Start_Date__c;
                String evalPhase = healthGoals[0].current_phase__c != null ? healthGoals[0].current_phase__c.toLowerCase() : 'maintenance';
                
                // Track execution for either stabilizing phase
                Boolean isCalorieTrackingState = (evalPhase == 'reverse' || evalPhase == 'maintenance');

                if (isCalorieTrackingState) {
                    Decimal dynamicTDEEVal = latestLog.TDEE__c != null ? latestLog.TDEE__c : 2500.0;
                    Integer expectedCalorieTarget = dynamicTDEEVal.intValue();
                    
                    // Maintain specific reverse scaling logic only if explicitly in reverse phase
                    if (evalPhase == 'reverse' && anchorDateGoal != null) {
                        Integer daysSinceGoal = anchorDateGoal.daysBetween(anchorDate);
                        expectedCalorieTarget = (Integer)(dynamicTDEEVal * 0.85);
                        if (daysSinceGoal >= 7 && daysSinceGoal < 14) expectedCalorieTarget += 150; 
                        else if (daysSinceGoal >= 14 && daysSinceGoal < 21) expectedCalorieTarget += 300; 
                        else if (daysSinceGoal >= 21) expectedCalorieTarget = dynamicTDEEVal.intValue(); 
                    }
                    
                    Decimal actualCalories = latestLog.Calories__c != null ? latestLog.Calories__c : 0.0;
                    Decimal calorieDeviation = (actualCalories - expectedCalorieTarget).abs();
                    Decimal stabilizationScore = 200.0 - (calorieDeviation * 0.8);
                    if (stabilizationScore < 0) stabilizationScore = 0;
                    res.healthIndex = stabilizationScore;
                    
                } else {
                    if (logs.size() < 2) res.healthIndex = 100;
                    else {
                        List<Health_Data__c> chronoLogs = new List<Health_Data__c>();
                        for(Integer i = logs.size()-1; i>=0; i--) { chronoLogs.add(logs[i]); }
                        Decimal weeklyWeightVelocity = calculateWeightSlope(chronoLogs) * 7.0;
                        Boolean isCuttingState = (evalPhase == 'cutting' || (weightTarget > 0 && latestLog.Weight_lbs__c > weightTarget));
                        res.healthIndex = calculateGradient(weeklyWeightVelocity, isCuttingState);
                    }
                }
            }
            outputs.add(res);
        }
        return outputs;
    }
    private static Decimal calculateGradient(Decimal velocity, Boolean isCutting) {
        Decimal absV = velocity.abs().setScale(2, RoundingMode.HALF_UP);
        if(isCutting) {
            if(absV <= 1.5) return 100;
            if(absV <= 2.5) return 100 + ((absV - 1.5) / 1.0) * 100; 
            if(absV <= 3.0) return 90 - ((absV - 2.5) / 0.5) * 90;   
            return 0;
        } else {
            if(velocity <= 0.0) return 0; 
            if(velocity < 0.09) return 50 + ((velocity / 0.09) * 50); 
            if(velocity < 0.18) return 100 + ((velocity - 0.09) / 0.09) * 100;
            if(velocity <= 0.22) return 200;
            if(velocity <= 0.50) return 200 - ((velocity - 0.22) / 0.28) * 100;
            if(velocity <= 0.75) return 100 - ((velocity - 0.50) / 0.25) * 60;  
            if(velocity <= 1.00) return 40 - ((velocity - 0.75) / 0.25) * 40;  
            return 0; 
        }
    }

    public class PerformanceInput {
        @InvocableVariable(required=true) public Decimal currentWeight;
        @InvocableVariable(required=true) public Date currentDate;
        @InvocableVariable(required=true) public Boolean isCutting;
    }

    public class PerformanceOutput {
        @InvocableVariable public Decimal healthIndex;
        @InvocableVariable public Decimal financialIndex;
    }

    @AuraEnabled
    public static List<Map<String, Object>> getFinancialHistory() { 
        List<Map<String, Object>> history = new List<Map<String, Object>>();
        for(financial_data__c trans : [SELECT Transaction_Amount__c, Transaction_Date__c, Transaction_Type__c 
                                       FROM financial_data__c 
                                       WHERE Transaction_Date__c != null 
                                       ORDER BY Transaction_Date__c ASC]) { 
            history.add(new Map<String, Object>{
                'entryDate' => String.valueOf(trans.Transaction_Date__c), 
                'amount' => trans.Transaction_Amount__c,
                'type' => trans.Transaction_Type__c
            }); 
        }
        return history;
    }
    
    @AuraEnabled
    public static List<Health_Data__c> getWeightHistory() { 
        return [SELECT Entry_Date__c, Weight_lbs__c, Calories__c, Protein_g__c, Carbs_g__c, Fat_g__c, TDEE__c, Body_Fat__c 
                FROM Health_Data__c 
                ORDER BY Entry_Date__c ASC]; 
    }
    
    @AuraEnabled
    public static List<Map<String, Object>> getTrailheadHistory() { 
        List<Map<String, Object>> agg = new List<Map<String, Object>>(); 
        for (AggregateResult ar : [SELECT Entry_Date__c, SUM(Points_Gained__c) dailyTotal FROM Trailhead_Log__c GROUP BY Entry_Date__c ORDER BY Entry_Date__c DESC LIMIT 7]) { agg.add(new Map<String, Object>{'entryDate' => ar.get('Entry_Date__c'), 'points' => ar.get('dailyTotal')}); } 
        return agg; 
    }
    
    @AuraEnabled 
    public static void saveTrailheadEntry(Integer points, Date entryDate) { insert new Trailhead_Log__c(Points_Gained__c = points, Entry_Date__c = entryDate); }
    
    @AuraEnabled 
    public static void undoLastEntry() { List<Trailhead_Log__c> lastEntry = [SELECT Id FROM Trailhead_Log__c ORDER BY CreatedDate DESC LIMIT 1]; if(!lastEntry.isEmpty()) { delete lastEntry; } }

    @AuraEnabled
    public static String getSovereignInsight(String payload, String nodeType) {
        try {
            return SovereignAIController.getSovereignInsight(payload, nodeType);
        } catch (Exception e) {
            return 'BRIDGE_ERROR: ' + e.getMessage();
        }
    }
}