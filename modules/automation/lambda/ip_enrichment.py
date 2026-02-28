import boto3 # type: ignore
import os
import logging
import json
import re
import urllib.request
import urllib.parse
from typing import Any, Dict, List, Optional, Set, Tuple

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")
secretsmanager = boto3.client("secretsmanager")
securityhub = boto3.client("securityhub")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
THREAT_INTEL_SECRET_ARN = os.environ.get("THREAT_INTEL_SECRET_ARN")
SECURITYHUB_REGION = os.environ.get("SECURITYHUB_REGION")
WRITE_TO_SECURITYHUB = os.environ.get("WRITE_TO_SECURITYHUB", "true")

# CACHE SECRET ACROSS INVOCATIONS
_cached_abuseipdb_key: Optional[str] = None

# BASIC IP REGEX
_IPV4_RE = re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\b")
# BASIC IPV6 REGEX
_IPV6_RE = re.compile(r"\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b")

# GUARDRAILS
MAX_IPS_PER_EVENT = int(os.environ.get("MAX_IPS_PER_EVENT", "25"))
ABUSEIPDB_MAX_AGE_DAYS = os.environ.get("ABUSEIPDB_MAX_AGE_DAYS", "90")


def _get_abuseipdb_api_key() -> Optional[str]:
    global _cached_abuseipdb_key

    if _cached_abuseipdb_key:
        return _cached_abuseipdb_key
    
    if not THREAT_INTEL_SECRET_ARN:
        logger.error("THREAT_INTEL_SECRET_ARN is not set.")
        return None
    
    try:
        resp = secretsmanager.get_secret_value(SecretId=THREAT_INTEL_SECRET_ARN)
        secret_str = resp.get("SecretString","")
        if not secret_str:
            logger.error("SecretString is empty for THREAT_INTEL_SECRET_ARN.")
            return None
        
        secret_json = json.loads(secret_str)
        key = secret_json.get("ABUSEIPDB_API_KEY") or secret_json.get("abuseipdb_api_key")
        if not key:
            logger.error("Secret does not contain ABUSEIPDB_API_KEY.")
            return None
        
        _cached_abuseipdb_key = key
        return key
    
    except Exception as e:
        logger.exception(f"Failed to read threat intel secret: {e}")
        return None
    

def _find_ips_in_obj(obj: Any, found: Set[str]) -> None:
    """Recursively scan strings in dict/list structures for IP-like patterns"""
    if obj is None:
        return
    if isinstance(obj, dict):
        for _, v in obj.items():
            _find_ips_in_obj(v, found)
    elif isinstance(obj, list):
        for v in obj:
            _find_ips_in_obj(v, found)
    elif isinstance(obj, str):
        for ip in _IPV4_RE.findall(obj):
            found.add(ip)
        for ip in _IPV6_RE.findall(obj):
            # FILTER OBVIOUS FALSE POSITIVES, LIKE "::::"
            if ":" in ip and len(ip) >= 3:
                found.add(ip)

def extract_ips_and_map_findings(findings: List[Dict[str, Any]]) -> Tuple[Set[str], Dict[str, Set[str]]]:
    """
    Returns:
        all_ips: unique set of IPs discovered across findings
        ip_to_finding_ids: map ip -> set of finding IDs that referenced it
    """
    all_ips: Set[str] = set()
    ip_to_finding_ids: Dict[str, Set[str]] = {}

    for f in findings:
        finding_id = f.get("Id", "Unknown")
        local_ips: Set[str] = set()

        # 1) NETWORK SECTION (COMMON IN GUARDDUTY-STYLE FINDINGS)
        network = f.get("Network") or {}
        for k in ("SourceIpV4", "SourceIpV6", "DestinationIpV4", "DestinationIpV6"):
            v = network.get(k)
            if isinstance(v, str) and v:
                local_ips.add(v)

        # 2) PRODUCTFIELDS (OFTEN CONTAIN IP-RELATED STRINGS)
        product_fields = f.get("ProductFields") or {}
        _find_ips_in_obj(product_fields, local_ips)

        # 3) GENERIC SCAN OF THE FINDING (SAFE FALLBACK)
        _find_ips_in_obj(f, local_ips)

        # NORMALIZE / RECORD FINDINGS
        for ip in local_ips:
            all_ips.add(ip)
            ip_to_finding_ids.setdefault(ip, set()).add(finding_id)

        if len(all_ips) >= MAX_IPS_PER_EVENT:
            logger.warning(f"Hit MAX_IPS_PER_EVENT={MAX_IPS_PER_EVENT}. Truncating.")
            break

    return all_ips, ip_to_finding_ids

def query_abuse_ipdb(ip: str, api_key: str) -> Optional[Dict[str, Any]]:
    url = "https://api.abuseipdb.com/api/v2/check"
    params = {
        "Accept": "application/json",
        "Key": api_key,
        "User-Agent": "tf-secure-baseline-ip-enrichment/1.0",
    }

    full_url = f"{url}?{urllib.parse.urlencode(params)}"

    try:
        req = urllib.request.Request(full_url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
            parsed = json.loads(body)
            return parsed.get("data", {})
        
    except Exception as e:
        logger.error(f"Error querying AbuseIPDB for {ip}: {e}")
        return None
    
def format_enrichment_message(enriched: List[Dict[str, Any]]) -> str:
    lines: List[str] = []
    lines.append("🧠 IP Threat Intel Enrichment")
    lines.append("")
    lines.append(f"Enriched IPs: {len(enriched)}")
    lines.append("")

    for entry in enriched:
        ip = entry.get("ip", "N/A")
        score = entry.get("abuseConfidenceScore", "N/A")
        country = entry.get("countryName", "N/A")
        isp = entry.get("isp", "N/A")
        usage = entry.get("usageType", "N/A")
        tor = entry.get("isTor", "N/A")
        reports = entry.get("reports", "N/A")
        last = entry.get("lastReportedAt", "N/A")
        finding_ids = entry.get("findingIds", [])

        lines.append(f"🌐 {ip}")
        lines.append(f"    • Abuse score: {score}")
        lines.append(f"    • Country: {country} | ISP: {isp} | Usage: {usage} | Tor: {tor}")
        lines.append(f"    • Reports: {reports} | Last reported: {last}")
        if finding_ids:
            lines.append(f"    • Finding IDs: {', '.join(finding_ids[:5])}{'…' if len(finding_ids) > 5 else ''}")
        lines.append("")
    
    return "\n".join(lines)

def publish_to_sns(subject: str, message: str) -> None:
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set; skipping publish.")
        return
    
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject[:100], # SNS subject line is 100 chars
            Message=message
        )
        logger.info("SNS notification sent.")
    except Exception as e:
        logger.error(f"Failed to publish to SNS: {e}")

def write_back_to_securityhub_note(finding_ids: Set[str], note_text: str) -> None:
    note_text = note_text

    try:
        # BatchUpdateFindings requires identifiers (Id + ProductArn)
        # Ids here are from the event; ProductArn is present in each finding.
        # Identifiers will be reconstructed from event payload in handler.
        pass
    except Exception as e:
        logger.error(f"Failed to write back to Security Hub: {e}")

def lambda_handler(event, context):
    findings = (event.get("detail") or {}).get("findings") or []
    if not findings:
        logger.warning("No findings in event.")
        return {"statuscode": 400, "body": json.dumps({"message": "No findings in event"})}
    
    api_key = _get_abuseipdb_api_key()
    if not api_key:
        return {"statuscode": 500, "body": json.dumps({"message": "Missing AbuseIPDB API key"})}
    
    all_ips, ip_to_finding_ids = extract_ips_and_map_findings(findings)
    logger.info(f"Unique IPs extracted: {len(all_ips)}")

    enriched: List[Dict[str, Any]] = []
    for ip in list(all_ips)[:MAX_IPS_PER_EVENT]:
        result = query_abuse_ipdb(ip, api_key)
        if not result:
            continue

        enriched.append({
            "ip": ip,
            "findingIds": sorted(list(ip_to_finding_ids.get(ip, set()))),
            "abuseConfidenceScore": result.get("abuseConfidenceScore"),
            "countryName": result.get("countryName"),
            "usageType": result.get("usageType"),
            "domain": result.get("domain"),
            "hostnames": result.get("hostnames"),
            "isp": result.get("isp"),
            "isTor": result.get("isTor"),
            "totalReports": result.get("totalReports"),
            "lastReportedAt": result.get("lastReportedAt"),
        })

    if not enriched:
        logger.info("No enrichment results returned.")
        return {"statusCode": 200, "body": json.dumps({"message": "No IPs enriched", "resultCount": 0})}
    
    message = format_enrichment_message(enriched)
    subject = f"🧠 IP Threat Intel Report: {len(enriched)} IP{'s' if len(enriched) != 1 else ''} Enriched"
    publish_to_sns(subject, message)

    if WRITE_TO_SECURITYHUB:
        try:
            identifiers = []
            for f in findings:
                fid = f.get("Id")
                product_arn = f.get("ProductArn")
                if fid and product_arn:
                    identifiers.append({"Id": fid, "ProductArn": product_arn})

            # Short note containing top enriched IPs and scores
            top = enriched[:5]
            note_lines = ["IP enrichment (AbuseIPDB):"]
            for e in top:
                note_lines.append(f"- {e['ip']}: score={e.get('abuseConfidenceScore')} country={e.get('countryCode')} tor={e.get('isTor')}")
            note = "\n".join(note_lines)

            securityhub.batch_update_findings(
                FindingIdentifiers=identifiers,
                Note={
                    "Text": note[:1024],
                    "UpdatedBy": "tf-secure-baseline/ip-enrichment",
                },
            )
            logger.info("Wrote enrichment note back to Security Hub findings.")
        except Exception as e:
            logger.error(f"Security Hub write-back failed: {e}")

    return {"statusCode": 200, "body": json.dumps({"message": "Processing complete", "resultCount": len(enriched)})}
