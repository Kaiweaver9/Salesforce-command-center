@RestResource(urlMapping='/HealthDataIngestion/*') 
global class HealthDataAPI {

    @HttpPost
    global static String upsertDailyMetrics() {
        RestRequest req = RestContext.request;
        String requestBody = req.requestBody != null ? req.requestBody.toString() : '';
        RestResponse res = RestContext.response;
        
        try {
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
            String dKey = (String) data.get('dateKey');
            
            // Convert to Date for comparison
            Date targetDate = Date.valueOf(dKey);
            Date todayDate = System.today();

            Health_data__c dailyRecord = new Health_data__c();
            dailyRecord.Date_Key__c = dKey; 
            dailyRecord.entry_date__c = targetDate; 
            
            // Map Macros
            if (data.get('calories') != null) dailyRecord.Calories__c = Decimal.valueOf(String.valueOf(data.get('calories')));
            if (data.get('protein') != null)  dailyRecord.protein_g__c = Decimal.valueOf(String.valueOf(data.get('protein')));
            if (data.get('carbs') != null)    dailyRecord.carbs_g__c = Decimal.valueOf(String.valueOf(data.get('carbs')));
            if (data.get('fats') != null)     dailyRecord.fat_g__c = Decimal.valueOf(String.valueOf(data.get('fats')));
            
            Boolean weightProvided = data.get('weight') != null;
            Boolean bfProvided = data.get('bodyFat') != null;

            // Direct Mapping
            if (weightProvided) dailyRecord.Weight_lbs__c = Decimal.valueOf(String.valueOf(data.get('weight')));
            if (bfProvided) dailyRecord.body_fat__c = Decimal.valueOf(String.valueOf(data.get('bodyFat')));

            // TEMPORAL GATE: Ghost Node ONLY fires if it is NOT today.
            // If it IS today, we force a hard wait for actual hardware input.
            if (targetDate < todayDate) {
                List<Health_data__c> todayRecord = [SELECT Id, Weight_lbs__c, body_fat__c FROM Health_data__c WHERE Date_Key__c = :dKey LIMIT 1];
                Boolean sfHasWeight = !todayRecord.isEmpty() && todayRecord[0].Weight_lbs__c != null;
                Boolean sfHasBF = !todayRecord.isEmpty() && todayRecord[0].body_fat__c != null;

                if ((!weightProvided && !sfHasWeight) || (!bfProvided && !sfHasBF)) {
                    List<Health_data__c> lastKnown = [
                        SELECT Weight_lbs__c, body_fat__c 
                        FROM Health_data__c 
                        WHERE Weight_lbs__c != null 
                          AND Date_Key__c < :dKey 
                        ORDER BY Date_Key__c DESC 
                        LIMIT 1
                    ];
                    
                    if (!lastKnown.isEmpty()) {
                        if (!weightProvided && !sfHasWeight) dailyRecord.Weight_lbs__c = lastKnown[0].Weight_lbs__c;
                        if (!bfProvided && !sfHasBF && lastKnown[0].body_fat__c != null) dailyRecord.body_fat__c = lastKnown[0].body_fat__c;
                    }
                }
            }
            
            upsert dailyRecord Date_Key__c;
            res.statusCode = 200;
            return 'Success';
            
        } catch (Exception e) {
            System.debug('Apex Exception: ' + e.getMessage());
            res.statusCode = 500;
            return 'Error: ' + e.getMessage();
        }
    }
}