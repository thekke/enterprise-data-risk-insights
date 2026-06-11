/*
Enterprise Data Risk Insights
SQL Server reporting views for the Power BI dashboard.

Assumed source tables:
- dbo.applications
- dbo.risks
- dbo.controls
- dbo.control_tests
- dbo.incidents
- dbo.issues_actions

Run in database:
EnterpriseDataRiskInsights
*/

USE EnterpriseDataRiskInsights;
GO

/* ------------------------------------------------------------
1. Base risk view
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_RiskBase AS
SELECT
    r.risk_id,
    r.application_id,
    a.application_name,
    a.business_unit,
    a.criticality,
    a.business_owner,
    a.technology_owner,
    a.data_sensitivity,
    r.risk_category,
    r.risk_title,
    r.risk_owner,
    r.inherent_score,
    r.residual_score,
    r.risk_status,
    r.identified_date,
    r.target_treatment_date,

    CASE
        WHEN r.residual_score >= 20 THEN 'Critical'
        WHEN r.residual_score >= 15 THEN 'High'
        WHEN r.residual_score >= 8 THEN 'Medium'
        ELSE 'Low'
    END AS residual_rating,

    CASE
        WHEN r.inherent_score >= 20 THEN 'Critical'
        WHEN r.inherent_score >= 15 THEN 'High'
        WHEN r.inherent_score >= 8 THEN 'Medium'
        ELSE 'Low'
    END AS inherent_rating,

    DATEDIFF(DAY, r.identified_date, GETDATE()) AS risk_age_days,

    CASE
        WHEN r.target_treatment_date < CAST(GETDATE() AS DATE)
             AND r.risk_status <> 'Closed'
        THEN 'Treatment Overdue'
        ELSE 'On Track / Closed'
    END AS treatment_status
FROM dbo.risks r
LEFT JOIN dbo.applications a
    ON r.application_id = a.application_id;
GO


/* ------------------------------------------------------------
2. Control effectiveness view
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_ControlEffectiveness AS
WITH test_summary AS (
    SELECT
        control_id,
        COUNT(*) AS total_tests,
        SUM(CASE WHEN test_result = 'Pass' THEN 1 ELSE 0 END) AS passed_tests,
        SUM(CASE WHEN test_result = 'Fail' THEN 1 ELSE 0 END) AS failed_tests,
        SUM(CASE WHEN test_result = 'Partial' THEN 1 ELSE 0 END) AS partial_tests,
        SUM(ISNULL(failed_samples, 0)) AS failed_samples,
        MAX(test_date) AS latest_test_date
    FROM dbo.control_tests
    GROUP BY control_id
)
SELECT
    c.control_id,
    c.risk_id,
    rb.risk_title,
    rb.risk_category,
    rb.application_name,
    rb.business_unit,
    rb.criticality,
    c.control_name,
    c.control_type,
    c.frequency,
    c.control_owner,
    c.control_status,
    c.key_control,
    ISNULL(ts.total_tests, 0) AS total_tests,
    ISNULL(ts.passed_tests, 0) AS passed_tests,
    ISNULL(ts.failed_tests, 0) AS failed_tests,
    ISNULL(ts.partial_tests, 0) AS partial_tests,
    ISNULL(ts.failed_samples, 0) AS failed_samples,
    ts.latest_test_date,

    CAST(
        100.0 * ISNULL(ts.passed_tests, 0)
        / NULLIF(ts.total_tests, 0)
        AS DECIMAL(5,2)
    ) AS pass_rate_pct,

    CASE
        WHEN ISNULL(ts.total_tests, 0) = 0 THEN 'Not Tested'
        WHEN ISNULL(ts.failed_tests, 0) >= 2 THEN 'Ineffective'
        WHEN ISNULL(ts.failed_tests, 0) = 1 OR ISNULL(ts.partial_tests, 0) >= 2 THEN 'Needs Attention'
        WHEN CAST(100.0 * ISNULL(ts.passed_tests, 0) / NULLIF(ts.total_tests, 0) AS DECIMAL(5,2)) >= 90 THEN 'Effective'
        ELSE 'Needs Attention'
    END AS control_effectiveness
FROM dbo.controls c
LEFT JOIN test_summary ts
    ON c.control_id = ts.control_id
LEFT JOIN dbo.vw_RiskBase rb
    ON c.risk_id = rb.risk_id;
GO


/* ------------------------------------------------------------
3. High residual data risks
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_HighResidualDataRisks AS
SELECT
    risk_id,
    application_id,
    application_name,
    business_unit,
    criticality,
    data_sensitivity,
    risk_category,
    risk_title,
    risk_owner,
    inherent_score,
    inherent_rating,
    residual_score,
    residual_rating,
    risk_status,
    treatment_status,
    target_treatment_date,

    CASE
        WHEN residual_score >= 20 THEN 'Immediate executive attention'
        WHEN residual_score >= 15 THEN 'Prioritise remediation'
        ELSE 'Monitor'
    END AS recommended_management_action
FROM dbo.vw_RiskBase
WHERE residual_score >= 15
  AND risk_status <> 'Closed';
GO


/* ------------------------------------------------------------
4. Overdue remediation actions
Includes ageing_band_sort for Power BI sorting.
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_OverdueRemediationActions AS
SELECT
    action_id,
    source_type,
    linked_record_id,
    action_title,
    action_owner,
    due_date,
    status,
    severity,

    DATEDIFF(DAY, due_date, GETDATE()) AS days_overdue,

    CASE
        WHEN DATEDIFF(DAY, due_date, GETDATE()) >= 90 THEN '90+ days'
        WHEN DATEDIFF(DAY, due_date, GETDATE()) >= 60 THEN '60-89 days'
        WHEN DATEDIFF(DAY, due_date, GETDATE()) >= 30 THEN '30-59 days'
        WHEN DATEDIFF(DAY, due_date, GETDATE()) > 0 THEN '1-29 days'
        ELSE 'Not overdue'
    END AS ageing_band,

    CASE
        WHEN DATEDIFF(DAY, due_date, GETDATE()) >= 90 THEN 1
        WHEN DATEDIFF(DAY, due_date, GETDATE()) >= 60 THEN 2
        WHEN DATEDIFF(DAY, due_date, GETDATE()) >= 30 THEN 3
        WHEN DATEDIFF(DAY, due_date, GETDATE()) > 0 THEN 4
        ELSE 5
    END AS ageing_band_sort,

    CASE
        WHEN severity IN ('High', 'Critical')
             AND DATEDIFF(DAY, due_date, GETDATE()) >= 60
        THEN 'Escalate'
        WHEN DATEDIFF(DAY, due_date, GETDATE()) >= 30
        THEN 'Management attention'
        ELSE 'Monitor'
    END AS action_priority
FROM dbo.issues_actions
WHERE status <> 'Closed'
  AND due_date < CAST(GETDATE() AS DATE);
GO


/* ------------------------------------------------------------
5. Data risk themes
Aggregated view used for theme and control weakness analysis.
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_DataRiskThemes AS
WITH risk_theme AS (
    SELECT
        risk_category,
        COUNT(*) AS total_risks,
        SUM(CASE WHEN residual_score >= 15 THEN 1 ELSE 0 END) AS high_residual_risks,
        AVG(CAST(residual_score AS FLOAT)) AS avg_residual_score
    FROM dbo.vw_RiskBase
    WHERE risk_status <> 'Closed'
    GROUP BY risk_category
),
control_theme AS (
    SELECT
        risk_category,
        SUM(failed_tests) AS failed_control_tests,
        SUM(partial_tests) AS partial_control_tests,
        COUNT(DISTINCT control_id) AS total_controls
    FROM dbo.vw_ControlEffectiveness
    GROUP BY risk_category
),
action_theme AS (
    SELECT
        rb.risk_category,
        COUNT(DISTINCT ia.action_id) AS open_actions,
        SUM(
            CASE
                WHEN ia.status <> 'Closed'
                 AND ia.due_date < CAST(GETDATE() AS DATE)
                THEN 1 ELSE 0
            END
        ) AS overdue_actions
    FROM dbo.issues_actions ia
    INNER JOIN dbo.vw_RiskBase rb
        ON ia.source_type = 'Risk'
       AND CAST(ia.linked_record_id AS VARCHAR(50)) = CAST(rb.risk_id AS VARCHAR(50))
    WHERE ia.status <> 'Closed'
    GROUP BY rb.risk_category
),
combined AS (
    SELECT
        rt.risk_category,
        rt.total_risks,
        rt.high_residual_risks,
        CAST(rt.avg_residual_score AS DECIMAL(5,2)) AS avg_residual_score,
        ISNULL(ct.total_controls, 0) AS total_controls,
        ISNULL(ct.failed_control_tests, 0) AS failed_control_tests,
        ISNULL(ct.partial_control_tests, 0) AS partial_control_tests,
        ISNULL(at.open_actions, 0) AS open_actions,
        ISNULL(at.overdue_actions, 0) AS overdue_actions,

        (
            rt.high_residual_risks * 5
            + ISNULL(ct.failed_control_tests, 0) * 1
            + ISNULL(at.overdue_actions, 0) * 4
        ) AS theme_risk_score
    FROM risk_theme rt
    LEFT JOIN control_theme ct
        ON rt.risk_category = ct.risk_category
    LEFT JOIN action_theme at
        ON rt.risk_category = at.risk_category
),
ranked AS (
    SELECT
        *,
        NTILE(3) OVER (ORDER BY theme_risk_score DESC) AS theme_band
    FROM combined
)
SELECT
    risk_category,
    total_risks,
    high_residual_risks,
    avg_residual_score,
    total_controls,
    failed_control_tests,
    partial_control_tests,
    open_actions,
    overdue_actions,
    theme_risk_score,

    CASE
        WHEN theme_band = 1 THEN 'Priority 1'
        WHEN theme_band = 2 THEN 'Priority 2'
        ELSE 'Monitor'
    END AS theme_priority
FROM ranked;
GO


/* ------------------------------------------------------------
6. Executive risk summary
Raw summary by business unit, including weighted risk exposure score.
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_ExecutiveRiskSummary AS
WITH business_units AS (
    SELECT DISTINCT
        business_unit
    FROM dbo.applications

    UNION

    SELECT
        'Enterprise / Audit' AS business_unit
),
risk_summary AS (
    SELECT
        business_unit,
        COUNT(DISTINCT application_id) AS applications_with_risks,
        COUNT(DISTINCT risk_id) AS total_risks,
        SUM(CASE WHEN residual_score >= 15 THEN 1 ELSE 0 END) AS high_residual_risks,
        AVG(CAST(residual_score AS FLOAT)) AS avg_residual_score
    FROM dbo.vw_RiskBase
    WHERE risk_status <> 'Closed'
    GROUP BY business_unit
),
control_summary AS (
    SELECT
        business_unit,
        COUNT(DISTINCT control_id) AS total_controls,
        SUM(failed_tests) AS failed_control_tests,
        SUM(partial_tests) AS partial_control_tests
    FROM dbo.vw_ControlEffectiveness
    GROUP BY business_unit
),
incident_summary AS (
    SELECT
        a.business_unit,
        COUNT(DISTINCT i.incident_id) AS total_incidents,
        SUM(CASE WHEN i.severity IN ('High', 'Major', 'Critical') THEN 1 ELSE 0 END) AS high_severity_incidents,
        SUM(CASE WHEN i.sla_breached = 1 THEN 1 ELSE 0 END) AS sla_breached_incidents
    FROM dbo.incidents i
    LEFT JOIN dbo.applications a
        ON i.application_id = a.application_id
    GROUP BY a.business_unit
),
action_mapped AS (
    SELECT
        ia.action_id,
        ia.status,
        ia.due_date,
        COALESCE(
            rb_risk.business_unit,
            rb_control_test.business_unit,
            app_incident.business_unit,
            'Enterprise / Audit'
        ) AS business_unit
    FROM dbo.issues_actions ia

    -- Source type: Risk
    LEFT JOIN dbo.vw_RiskBase rb_risk
        ON ia.source_type = 'Risk'
       AND CAST(ia.linked_record_id AS VARCHAR(50)) = CAST(rb_risk.risk_id AS VARCHAR(50))

    -- Source type: Control Test
    -- action -> control test -> control -> risk -> application
    LEFT JOIN dbo.control_tests ct
        ON ia.source_type = 'Control Test'
       AND CAST(ia.linked_record_id AS VARCHAR(50)) = CAST(ct.test_id AS VARCHAR(50))

    LEFT JOIN dbo.controls c_from_test
        ON ct.control_id = c_from_test.control_id

    LEFT JOIN dbo.vw_RiskBase rb_control_test
        ON c_from_test.risk_id = rb_control_test.risk_id

    -- Source type: Incident PIR
    -- action -> incident -> application
    LEFT JOIN dbo.incidents i
        ON ia.source_type = 'Incident PIR'
       AND CAST(ia.linked_record_id AS VARCHAR(50)) = CAST(i.incident_id AS VARCHAR(50))

    LEFT JOIN dbo.applications app_incident
        ON i.application_id = app_incident.application_id
),
action_summary AS (
    SELECT
        business_unit,
        COUNT(DISTINCT action_id) AS open_actions,
        SUM(
            CASE
                WHEN status <> 'Closed'
                 AND due_date < CAST(GETDATE() AS DATE)
                THEN 1 ELSE 0
            END
        ) AS overdue_actions
    FROM action_mapped
    WHERE status <> 'Closed'
    GROUP BY business_unit
),
combined_summary AS (
    SELECT
        bu.business_unit,

        ISNULL(rs.applications_with_risks, 0) AS applications_with_risks,
        ISNULL(rs.total_risks, 0) AS total_risks,
        ISNULL(rs.high_residual_risks, 0) AS high_residual_risks,
        CAST(ISNULL(rs.avg_residual_score, 0) AS DECIMAL(5,2)) AS avg_residual_score,

        ISNULL(cs.total_controls, 0) AS total_controls,
        ISNULL(cs.failed_control_tests, 0) AS failed_control_tests,
        ISNULL(cs.partial_control_tests, 0) AS partial_control_tests,

        ISNULL(ins.total_incidents, 0) AS total_incidents,
        ISNULL(ins.high_severity_incidents, 0) AS high_severity_incidents,
        ISNULL(ins.sla_breached_incidents, 0) AS sla_breached_incidents,

        ISNULL(acts.open_actions, 0) AS open_actions,
        ISNULL(acts.overdue_actions, 0) AS overdue_actions
    FROM business_units bu
    LEFT JOIN risk_summary rs
        ON bu.business_unit = rs.business_unit
    LEFT JOIN control_summary cs
        ON bu.business_unit = cs.business_unit
    LEFT JOIN incident_summary ins
        ON bu.business_unit = ins.business_unit
    LEFT JOIN action_summary acts
        ON bu.business_unit = acts.business_unit
)
SELECT
    business_unit,
    applications_with_risks,
    total_risks,
    high_residual_risks,
    avg_residual_score,
    total_controls,
    failed_control_tests,
    partial_control_tests,
    total_incidents,
    high_severity_incidents,
    sla_breached_incidents,
    open_actions,
    overdue_actions,

    (
        high_residual_risks * 5
        + failed_control_tests * 1
        + overdue_actions * 4
        + high_severity_incidents * 3
    ) AS risk_exposure_score,

    CASE
        WHEN (
            high_residual_risks * 5
            + failed_control_tests * 1
            + overdue_actions * 4
            + high_severity_incidents * 3
        ) >= 55
        THEN 'Red'

        WHEN (
            high_residual_risks * 5
            + failed_control_tests * 1
            + overdue_actions * 4
            + high_severity_incidents * 3
        ) >= 35
        THEN 'Amber'

        ELSE 'Green'
    END AS executive_rag
FROM combined_summary;
GO


/* ------------------------------------------------------------
7. Final executive risk summary
Applies relative RAG so the dashboard supports prioritisation.
Used on Page 1.
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_ExecutiveRiskSummary_Final AS
WITH ranked AS (
    SELECT
        *,
        NTILE(3) OVER (ORDER BY risk_exposure_score DESC) AS risk_band
    FROM dbo.vw_ExecutiveRiskSummary
)
SELECT
    business_unit,
    applications_with_risks,
    total_risks,
    high_residual_risks,
    avg_residual_score,
    total_controls,
    failed_control_tests,
    partial_control_tests,
    total_incidents,
    high_severity_incidents,
    sla_breached_incidents,
    open_actions,
    overdue_actions,
    risk_exposure_score,

    CASE
        WHEN risk_band = 1 THEN 'Red'
        WHEN risk_band = 2 THEN 'Amber'
        ELSE 'Green'
    END AS executive_rag
FROM ranked;
GO


/* ------------------------------------------------------------
8. Data quality checks
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_DataQualityChecks AS

-- Risks missing owners
SELECT
    'Risks missing owner' AS issue_type,
    'Risks' AS source_table,
    COUNT(*) AS issue_count,
    'High' AS severity,
    'Risk records without accountable owners weaken governance and follow-up.' AS why_it_matters
FROM dbo.risks
WHERE risk_owner IS NULL OR LTRIM(RTRIM(risk_owner)) = ''

UNION ALL

-- Controls missing owners
SELECT
    'Controls missing owner',
    'Controls',
    COUNT(*),
    'High',
    'Controls without owners create accountability gaps in control operation and testing.'
FROM dbo.controls
WHERE control_owner IS NULL OR LTRIM(RTRIM(control_owner)) = ''

UNION ALL

-- Critical applications missing technology owner
SELECT
    'Critical applications missing technology owner',
    'Applications',
    COUNT(*),
    'High',
    'Critical applications require clear ownership for risk, incident and remediation accountability.'
FROM dbo.applications
WHERE criticality = 'Critical'
  AND (technology_owner IS NULL OR LTRIM(RTRIM(technology_owner)) = '')

UNION ALL

-- High residual risks without linked controls
SELECT
    'High residual risks without linked controls',
    'Risks / Controls',
    COUNT(*),
    'Critical',
    'High residual risks without controls may indicate untreated or poorly governed risk exposure.'
FROM dbo.vw_RiskBase rb
LEFT JOIN dbo.controls c
    ON rb.risk_id = c.risk_id
WHERE rb.residual_score >= 15
  AND rb.risk_status <> 'Closed'
  AND c.control_id IS NULL

UNION ALL

-- Overdue actions without owner
SELECT
    'Overdue actions without owner',
    'Issues_Actions',
    COUNT(*),
    'High',
    'Overdue remediation without ownership increases the risk that issues remain unresolved.'
FROM dbo.issues_actions
WHERE status <> 'Closed'
  AND due_date < CAST(GETDATE() AS DATE)
  AND (action_owner IS NULL OR LTRIM(RTRIM(action_owner)) = '');
GO


/* ------------------------------------------------------------
9. Management attention items
Combines high residual risks, weak controls and overdue actions.
Used on Page 3.
------------------------------------------------------------ */

CREATE OR ALTER VIEW dbo.vw_ManagementAttentionItems AS

-- High residual data risks
SELECT
    'High Residual Risk' AS item_type,
    CAST(risk_id AS VARCHAR(50)) AS item_id,
    risk_title AS item_title,
    business_unit,
    application_name,
    risk_owner AS owner,
    residual_score AS priority_score,
    residual_rating AS severity,
    recommended_management_action AS recommended_action
FROM dbo.vw_HighResidualDataRisks

UNION ALL

-- Weak / ineffective controls
SELECT
    'Weak / Ineffective Control' AS item_type,
    CAST(control_id AS VARCHAR(50)) AS item_id,
    control_name AS item_title,
    business_unit,
    application_name,
    control_owner AS owner,
    failed_tests + partial_tests AS priority_score,
    control_effectiveness AS severity,
    CASE
        WHEN control_effectiveness = 'Ineffective' THEN 'Escalate control remediation and retesting'
        WHEN control_effectiveness = 'Needs Attention' THEN 'Review control design and recent test failures'
        WHEN control_effectiveness = 'Not Tested' THEN 'Confirm testing schedule and control ownership'
        ELSE 'Monitor'
    END AS recommended_action
FROM dbo.vw_ControlEffectiveness
WHERE control_effectiveness IN ('Ineffective', 'Needs Attention', 'Not Tested')

UNION ALL

-- Overdue remediation actions enriched by actual source_type values
SELECT
    'Overdue Remediation' AS item_type,
    CAST(oa.action_id AS VARCHAR(50)) AS item_id,
    oa.action_title AS item_title,

    COALESCE(
        rb_risk.business_unit,
        rb_control_test.business_unit,
        app_incident.business_unit,
        'Enterprise / Audit'
    ) AS business_unit,

    COALESCE(
        rb_risk.application_name,
        rb_control_test.application_name,
        app_incident.application_name,
        'Not application-specific'
    ) AS application_name,

    oa.action_owner AS owner,
    oa.days_overdue AS priority_score,
    oa.severity,
    oa.action_priority AS recommended_action
FROM dbo.vw_OverdueRemediationActions oa

-- Source type: Risk
LEFT JOIN dbo.vw_RiskBase rb_risk
    ON oa.source_type = 'Risk'
   AND CAST(oa.linked_record_id AS VARCHAR(50)) = CAST(rb_risk.risk_id AS VARCHAR(50))

-- Source type: Control Test
-- action -> control test -> control -> risk -> application
LEFT JOIN dbo.control_tests ct
    ON oa.source_type = 'Control Test'
   AND CAST(oa.linked_record_id AS VARCHAR(50)) = CAST(ct.test_id AS VARCHAR(50))

LEFT JOIN dbo.controls c_from_test
    ON ct.control_id = c_from_test.control_id

LEFT JOIN dbo.vw_RiskBase rb_control_test
    ON c_from_test.risk_id = rb_control_test.risk_id

-- Source type: Incident PIR
-- action -> incident -> application
LEFT JOIN dbo.incidents i
    ON oa.source_type = 'Incident PIR'
   AND CAST(oa.linked_record_id AS VARCHAR(50)) = CAST(i.incident_id AS VARCHAR(50))

LEFT JOIN dbo.applications app_incident
    ON i.application_id = app_incident.application_id;
GO


/* ------------------------------------------------------------
Optional validation queries

SELECT TOP 20 * FROM dbo.vw_RiskBase ORDER BY residual_score DESC;
SELECT TOP 20 * FROM dbo.vw_ControlEffectiveness ORDER BY failed_tests DESC, partial_tests DESC;
SELECT * FROM dbo.vw_HighResidualDataRisks ORDER BY residual_score DESC;
SELECT * FROM dbo.vw_OverdueRemediationActions ORDER BY ageing_band_sort, days_overdue DESC;
SELECT * FROM dbo.vw_DataRiskThemes ORDER BY theme_risk_score DESC;
SELECT * FROM dbo.vw_ExecutiveRiskSummary_Final ORDER BY risk_exposure_score DESC;
SELECT * FROM dbo.vw_DataQualityChecks ORDER BY issue_count DESC;
SELECT TOP 50 * FROM dbo.vw_ManagementAttentionItems ORDER BY priority_score DESC;
------------------------------------------------------------ */
