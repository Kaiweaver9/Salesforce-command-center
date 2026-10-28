public with sharing class SovereignAIController {
    
    @AuraEnabled
    public static String getSovereignInsight(String payload, String nodeType) {
        Integer maxRetries = 3;
        Integer retryDelayMs = 1000; 
        
        for (Integer attempt = 0; attempt < maxRetries; attempt++) {
            try {
                HttpRequest req = new HttpRequest();
                req.setEndpoint('callout:Gemini_Named/v1beta/models/gemini-1.5-flash:generateContent');
                req.setMethod('POST');
                req.setHeader('Content-Type', 'application/json');

                String systemInstruction = 'IDENTITY: High-performance strategist peer. PROTOCOL: Direct, intense. \n';
                systemInstruction += (nodeType == 'PerformanceIndex' || nodeType == 'CenterNode' || nodeType == 'SystemSync') ? 
                    'MODE: SYSTEMIC OVERVIEW.' : 'MODE: TACTICAL PUNCH. Max 3 sentences.';

                Map<String, Object> body = new Map<String, Object>{
                    'contents' => new List<Object>{
                        new Map<String, Object>{
                            'parts' => new List<Object>{
                                new Map<String, Object>{ 'text' => systemInstruction + '\n\nDATA SOURCE:\n' + payload }
                            }
                        }
                    }
                };

                req.setBody(JSON.serialize(body));
                req.setTimeout(20000); 

                Http http = new Http();
                HTTPResponse res = http.send(req);
                Integer statusCode = res.getStatusCode();

                if (statusCode == 200) {
                    Map<String, Object> results = (Map<String, Object>)JSON.deserializeUntyped(res.getBody());
                    List<Object> candidates = (List<Object>)results.get('candidates');
                    if (candidates != null && !candidates.isEmpty()) {
                        Map<String, Object> cand = (Map<String, Object>)candidates[0];
                        Map<String, Object> cont = (Map<String, Object>)cand.get('content');
                        List<Object> parts = (List<Object>)cont.get('parts');
                        return (String)((Map<String, Object>)parts[0]).get('text');
                    }
                    return 'SYSTEM_IDLE: Gemini returned empty content.';
                } 
                
                if (statusCode == 429 && attempt < maxRetries - 1) {
                    Long start = DateTime.now().getTime();
                    while (DateTime.now().getTime() < start + retryDelayMs) { /* Wait */ }
                    retryDelayMs += 1000;
                    continue; 
                }

                return 'OFFLINE: Gemini Status ' + statusCode;

            } catch (Exception e) {
                if (attempt == maxRetries - 1) {
                    return 'BRIDGE_FAILURE: ' + e.getMessage();
                }
                // Small pause before retrying a connection error
                Long start = DateTime.now().getTime();
                while (DateTime.now().getTime() < start + 500) { }
            }
        }
        return 'SYSTEM_BREACH: Strategy Exhausted.';
    }
}