global class SovereignDebtEngine implements Schedulable {
    
    global void execute(SchedulableContext sc) {
        // 1. Identify the targets - pulling in Principal_Balance__c for pure mathematical anchoring
        List<Financial_Account__c> loans = [
            SELECT Id, Name, Current_Value__c, Interest_Rate__c, Principal_Balance__c 
            FROM Financial_Account__c 
            WHERE Name IN ('Student Loans Group: AA', 'Student Loans Group: AB')
            AND Interest_Rate__c != NULL 
            AND Principal_Balance__c != NULL
        ];
        
        List<Financial_Account__c> updates = new List<Financial_Account__c>();
        
        for(Financial_Account__c loan : loans) {
            // 2. Simple Daily Interest Formula
            // Enforce Math.abs() on Principal_Balance__c to ensure dailyInterest yields a positive absolute value.
            // Federal standard divides by 365, but 365.25 can be retained to scale seamlessly through leap cycles.
            Decimal annualRateDecimal = loan.Interest_Rate__c / 100.0;
            Decimal dailyInterest = (Math.abs(loan.Principal_Balance__c) * annualRateDecimal) / 365.25;
            
            // 3. Update Value
            // Since Current_Value__c is a negative debt balance, subtracting a strictly positive dailyInterest 
            // deepens the liability accurately without flipping tracking parameters.
            loan.Current_Value__c -= dailyInterest.setScale(2, System.RoundingMode.HALF_UP);
            
            updates.add(loan);
        }
        
        if(!updates.isEmpty()) {
            update updates;
        }
    }
}