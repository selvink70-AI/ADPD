/* ============================================================================
   ADPerfDashboard - 02_StoredProcedures.sql
   Database : ADS-Stats  (edm-goa-sql-1)
   Purpose  : Lookup tables, view + stored procedures consumed by the web
              application. All application data access goes through these
              procedures with typed parameters — no ad-hoc SQL from the app.
   Safe to re-run: every object is CREATE OR ALTER / IF NOT EXISTS.
   Does NOT modify any row in dbo.ADPerfMonData.

   NOTES
   - Server names are NORMALISED in the view (quotes stripped, lower-cased,
     short names expanded to FQDN) so "edm-goa-dc-2", "\"edm-goa-dc-2\"" and
     edm-goa-dc-2.goa.ds.gov.ab.ca all appear as ONE domain controller.
   - Domain (DS / GOA / Extern) is derived from the FQDN suffix using
     dbo.ADDomains. Longest suffix wins, so goa.ds.gov.ab.ca → GOA, not DS.
   - ReportDate2 (DATETIME) is the authoritative date column.
   - PerfMon "Avg. Disk sec/Read|Write" is stored in SECONDS; the view
     converts to MILLISECONDS. Remove "* 1000.0" if already in ms.
   ========================================================================== */
USE [ADS-Stats];
GO

/* ---------------------------------------------------------------------------
   Site map (optional, for the Site filter).
   --------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.ADServerSites', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ADServerSites
    (
        [Server] NVARCHAR(128) NOT NULL CONSTRAINT PK_ADServerSites PRIMARY KEY CLUSTERED,
        [Site]   NVARCHAR(128) NOT NULL
    );
END
GO

/* ---------------------------------------------------------------------------
   Domain lookup. One row per AD domain.
     DomainSuffix     : FQDN suffix of DCs in that domain
     ShortNamePattern : LIKE pattern used to expand short host names to FQDN
     SortOrder        : display order in the dashboard
   Add a row here to support a new domain — no code change needed.
   --------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.ADDomains', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ADDomains
    (
        DomainName       NVARCHAR(64)  NOT NULL CONSTRAINT PK_ADDomains PRIMARY KEY CLUSTERED,
        DomainSuffix     NVARCHAR(128) NOT NULL,
        ShortNamePattern NVARCHAR(64)  NOT NULL,
        SortOrder        INT           NOT NULL
    );
END
GO

MERGE dbo.ADDomains AS t
USING (VALUES
    (N'DS',     N'ds.gov.ab.ca',      N'%-ds-dc-%',  1),
    (N'GOA',    N'goa.ds.gov.ab.ca',  N'%-goa-dc-%', 2),
    (N'Extern', N'extern.gov.ab.ca',  N'%-ext-dc-%', 3)
) AS s (DomainName, DomainSuffix, ShortNamePattern, SortOrder)
ON t.DomainName = s.DomainName
WHEN MATCHED THEN UPDATE SET DomainSuffix = s.DomainSuffix,
                             ShortNamePattern = s.ShortNamePattern,
                             SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (DomainName, DomainSuffix, ShortNamePattern, SortOrder)
                      VALUES (s.DomainName, s.DomainSuffix, s.ShortNamePattern, s.SortOrder);
GO

/* ---------------------------------------------------------------------------
   vw_ADPerfMonData : maps raw columns to the aliases the application binds
   to, normalises server names, derives Domain, converts disk latency to ms,
   and joins the optional site map.
   --------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_ADPerfMonData
AS
SELECT
    d.id                                                          AS Id,
    f.ServerFqdn                                                  AS [Server],
    COALESCE(dom.DomainName, N'Other')                            AS [Domain],
    s.[Site]                                                      AS [Site],
    d.system_system_up_time                                       AS SystemUpTimeSeconds,
    d.memory_available_mbytes                                     AS MemoryAvailableMBytes,
    d.memory_pages_sec                                            AS MemoryPagesSec,
    d.memory_free_system_page_table_entries                       AS MemoryFreePageTableEntries,
    d.memory_pool_nonpaged_bytes                                  AS MemoryPoolNonPagedBytes,
    d.memory_pool_paged_bytes                                     AS MemoryPoolPagedBytes,
    d.process_lsass_processor_time                                AS LsassProcessorTime,
    d.process_lsass_working_set                                   AS LsassWorkingSet,
    d.physicaldisk_0_c_avg_disk_sec_read      * 1000.0            AS DiskCReadMs,
    d.physicaldisk_1_d_avg_disk_sec_read      * 1000.0            AS DiskDReadMs,
    d.physicaldisk_total_avg_disk_sec_read    * 1000.0            AS DiskTotalReadMs,
    d.physicaldisk_0_c_avg_disk_sec_write     * 1000.0            AS DiskCWriteMs,
    d.physicaldisk_1_d_avg_disk_sec_write     * 1000.0            AS DiskDWriteMs,
    d.physicaldisk_total_avg_disk_sec_write   * 1000.0            AS DiskTotalWriteMs,
    d.security_system_wide_statistics_kerberos_authentications    AS KerberosAuthentications,
    d.security_system_wide_statistics_ntlm_authentications        AS NtlmAuthentications,
    d.directoryservices_ntds_ldap_bind_time                       AS LdapBindTime,
    d.directoryservices_ntds_ldap_searches_sec                    AS LdapSearchesSec,
    d.directoryservices_ntds_ldap_client_sessions                 AS LdapClientSessions,
    d.directoryservices_ntds_ab_client_sessions                   AS AbClientSessions,
    d.directoryservices_ntds_ldap_successful_binds_sec            AS LdapSuccessfulBindsSec,
    d.directoryservices_ntds_ldap_new_connections_sec             AS LdapNewConnectionsSec,
    d.directoryservices_ntds_ldap_closed_connections_sec          AS LdapClosedConnectionsSec,
    d.directoryservices_ntds_ds_server_name_translations_sec      AS DsServerNameTranslationsSec,
    d.directoryservices_ntds_ds_client_name_translations_sec      AS DsClientNameTranslationsSec,
    d.server_errors_logon                                         AS ServerErrorsLogon,
    d.server_server_sessions                                      AS ServerSessions,
    d.server_logon_total                                          AS LogonTotal,
    d.server_logon_sec                                            AS LogonSec,
    d.Total_Days                                                  AS TotalDays,
    d.Logons_Per_Day                                              AS LogonsPerDay,
    d.ReportDate2                                                 AS ReportDate
FROM dbo.ADPerfMonData d
/* 1. strip quotes / whitespace, lower-case */
CROSS APPLY (SELECT LOWER(LTRIM(RTRIM(REPLACE(REPLACE(d.[Server], N'"', N''), N'''', N'')))) AS n) c
/* 2. expand short host names to FQDN using the domain's name pattern */
CROSS APPLY (SELECT CASE
                        WHEN CHARINDEX(N'.', c.n) > 0 THEN c.n
                        ELSE c.n + COALESCE((SELECT TOP (1) N'.' + x.DomainSuffix
                                             FROM dbo.ADDomains x
                                             WHERE c.n LIKE x.ShortNamePattern
                                             ORDER BY x.SortOrder), N'')
                    END AS ServerFqdn) f
/* 3. domain = longest matching suffix (goa.ds.gov.ab.ca beats ds.gov.ab.ca) */
OUTER APPLY (SELECT TOP (1) x.DomainName
             FROM dbo.ADDomains x
             WHERE f.ServerFqdn LIKE N'%.' + x.DomainSuffix
             ORDER BY LEN(x.DomainSuffix) DESC) dom
LEFT JOIN dbo.ADServerSites s ON s.[Server] = f.ServerFqdn;
GO

/* ---------------------------------------------------------------------------
   usp_GetLatestSnapshot : newest row per (normalised) server.
   Used by: summary cards, domain cards, overview grid.
   --------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_GetLatestSnapshot
    @Server   NVARCHAR(128) = NULL,
    @Site     NVARCHAR(128) = NULL,
    @Domain   NVARCHAR(64)  = NULL,
    @DateFrom DATETIME      = NULL,
    @DateTo   DATETIME      = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Ranked AS
    (
        SELECT v.*,
               ROW_NUMBER() OVER (PARTITION BY v.[Server] ORDER BY v.ReportDate DESC, v.Id DESC) AS rn
        FROM dbo.vw_ADPerfMonData v
        WHERE (@Server   IS NULL OR v.[Server] = @Server)
          AND (@Site     IS NULL OR v.[Site]   = @Site)
          AND (@Domain   IS NULL OR v.[Domain] = @Domain)
          AND (@DateFrom IS NULL OR v.ReportDate >= @DateFrom)
          AND (@DateTo   IS NULL OR v.ReportDate <  DATEADD(DAY, 1, @DateTo))
    )
    SELECT *
    FROM Ranked
    WHERE rn = 1
    ORDER BY [Domain], [Server];
END
GO

/* ---------------------------------------------------------------------------
   usp_GetServerHistory : all rows for one server over the last @Days days.
   Used by: Server Details page (sparklines, 90-day charts, min/max/avg).
   --------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_GetServerHistory
    @Server NVARCHAR(128),
    @Days   INT = 90
AS
BEGIN
    SET NOCOUNT ON;

    SELECT *
    FROM dbo.vw_ADPerfMonData
    WHERE [Server] = @Server
      AND ReportDate >= DATEADD(DAY, -@Days, GETDATE())
    ORDER BY ReportDate ASC;
END
GO

/* ---------------------------------------------------------------------------
   usp_GetDailyTrends : one averaged row per server per day.
   Used by: every trend chart and heatmap.
   --------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_GetDailyTrends
    @Days   INT           = 30,
    @Server NVARCHAR(128) = NULL,
    @Site   NVARCHAR(128) = NULL,
    @Domain NVARCHAR(64)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        v.[Server]                                   AS [Server],
        v.[Domain]                                   AS [Domain],
        CAST(v.ReportDate AS DATE)                   AS [Day],
        AVG(v.KerberosAuthentications)               AS Kerberos,
        AVG(v.NtlmAuthentications)                   AS Ntlm,
        AVG(v.LogonSec)                              AS LogonSec,
        MAX(v.LogonTotal)                            AS LogonTotal,
        MAX(v.ServerErrorsLogon)                     AS LogonErrors,
        AVG(v.LdapSearchesSec)                       AS LdapSearchesSec,
        AVG(v.LdapBindTime)                          AS LdapBindTime,
        AVG(v.LdapClientSessions)                    AS LdapClientSessions,
        AVG(v.LdapSuccessfulBindsSec)                AS LdapSuccessfulBindsSec,
        AVG(v.LdapNewConnectionsSec)                 AS LdapNewConnectionsSec,
        AVG(v.LdapClosedConnectionsSec)              AS LdapClosedConnectionsSec,
        AVG(v.DsServerNameTranslationsSec)           AS ServerNameTranslationsSec,
        AVG(v.DsClientNameTranslationsSec)           AS ClientNameTranslationsSec,
        AVG(v.MemoryAvailableMBytes)                 AS MemoryAvailableMBytes,
        AVG(v.MemoryPagesSec)                        AS MemoryPagesSec,
        AVG(v.MemoryPoolPagedBytes)                  AS MemoryPoolPagedBytes,
        AVG(v.MemoryPoolNonPagedBytes)               AS MemoryPoolNonPagedBytes,
        AVG(v.MemoryFreePageTableEntries)            AS MemoryFreePageTableEntries,
        AVG(v.DiskCReadMs)                           AS DiskCReadMs,
        AVG(v.DiskDReadMs)                           AS DiskDReadMs,
        AVG(v.DiskTotalReadMs)                       AS DiskTotalReadMs,
        AVG(v.DiskCWriteMs)                          AS DiskCWriteMs,
        AVG(v.DiskDWriteMs)                          AS DiskDWriteMs,
        AVG(v.DiskTotalWriteMs)                      AS DiskTotalWriteMs,
        AVG(v.LsassProcessorTime)                    AS LsassCpu,
        AVG(v.LsassWorkingSet)                       AS LsassWorkingSet
    FROM dbo.vw_ADPerfMonData v
    WHERE v.ReportDate >= DATEADD(DAY, -@Days, GETDATE())
      AND (@Server IS NULL OR v.[Server] = @Server)
      AND (@Site   IS NULL OR v.[Site]   = @Site)
      AND (@Domain IS NULL OR v.[Domain] = @Domain)
    GROUP BY v.[Server], v.[Domain], CAST(v.ReportDate AS DATE)
    ORDER BY [Day] ASC, v.[Server] ASC;
END
GO

/* ---------------------------------------------------------------------------
   usp_GetServers : distinct (normalised) DC names for drop-downs.
   --------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_GetServers
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT [Server]
    FROM dbo.vw_ADPerfMonData
    ORDER BY [Server];
END
GO

/* ---------------------------------------------------------------------------
   usp_GetSites : distinct site names for the filter drop-down.
   --------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_GetSites
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT [Site]
    FROM dbo.ADServerSites
    ORDER BY [Site];
END
GO

/* ---------------------------------------------------------------------------
   usp_GetDomains : domain names for the filter drop-down / domain cards.
   --------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_GetDomains
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DomainName
    FROM dbo.ADDomains
    ORDER BY SortOrder, DomainName;
END
GO

/* ---------------------------------------------------------------------------
   usp_GetHistoryPaged : raw history page for lazy-loaded grids.
   Returns two result sets: (1) total row count, (2) requested page.
   --------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_GetHistoryPaged
    @Server   NVARCHAR(128) = NULL,
    @Domain   NVARCHAR(64)  = NULL,
    @DateFrom DATETIME      = NULL,
    @DateTo   DATETIME      = NULL,
    @Offset   INT           = 0,
    @PageSize INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageSize > 500 SET @PageSize = 500;
    IF @PageSize < 1   SET @PageSize = 25;
    IF @Offset   < 0   SET @Offset   = 0;

    SELECT COUNT(*)
    FROM dbo.vw_ADPerfMonData v
    WHERE (@Server   IS NULL OR v.[Server] = @Server)
      AND (@Domain   IS NULL OR v.[Domain] = @Domain)
      AND (@DateFrom IS NULL OR v.ReportDate >= @DateFrom)
      AND (@DateTo   IS NULL OR v.ReportDate <  DATEADD(DAY, 1, @DateTo));

    SELECT *
    FROM dbo.vw_ADPerfMonData v
    WHERE (@Server   IS NULL OR v.[Server] = @Server)
      AND (@Domain   IS NULL OR v.[Domain] = @Domain)
      AND (@DateFrom IS NULL OR v.ReportDate >= @DateFrom)
      AND (@DateTo   IS NULL OR v.ReportDate <  DATEADD(DAY, 1, @DateTo))
    ORDER BY v.ReportDate DESC, v.[Server] ASC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ---------------------------------------------------------------------------
   Permission for the new procedure (role created by 03_Security.sql).
   --------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ADPerfDashboardReader' AND type = 'R')
    GRANT EXECUTE ON dbo.usp_GetDomains TO ADPerfDashboardReader;
GO

PRINT '02_StoredProcedures.sql completed.';
GO
