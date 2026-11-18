"""The satmux relay's AWS resources in FINN staging: apply, status, run on the host, put the key, destroy.

Runs inside Executor's AWS sandbox (`aws___run_script`), which provides `call_boto3` and allows only the
`asyncio` and `json` imports. deploy.sh sends this file without its `# local-only` lines (it defines stand-ins
for the type names, since it allows no class definitions), with one line appended that calls `main` with the action and its config, and reads back
the line that starts with RESULT. Executor stops waiting after about a minute, so no action waits long; apply
returns pending until the new instance can take its Elastic IP, and deploy.sh applies again. Every step finds its resource by
name or tag first, so apply can run again at any time and changes only what is missing.
"""

from __future__ import annotations  # local-only: CI runs Python 3.9

import asyncio
import json
from collections.abc import Awaitable, Callable  # local-only: deploy.sh drops these lines for the sandbox
from typing import Any  # local-only

Call = Callable[..., Awaitable[dict[str, Any]]]  # local-only

REGION = "ap-southeast-1"
NAME = "satmux-relay"
PORT = 8444
# Also taken on 443 (the host redirects it to PORT): cabin and hotel Wi-Fi block 8444 and let 443 through, and the
# Worker hands out 443 (deploy.sh, worker_port).
PUBLIC_PORT = 443
PSK_PARAMETER = "/satmux/psk"
# The host's check-in bearer for the Agent Pager monitor Worker (docs/api/monitors.md §4.27), the EC2 hosts' convention.
MONITOR_TOKEN_PARAMETER = "/agent-pager/monitor-tokens/satmux-relay"
MONITOR_URL = "https://finn-agent-monitor-production.finn-atlas.workers.dev/monitors/satmux-relay/check-in"
INSTANCE_TYPE = "t4g.nano"
# Amazon Linux 2023, arm64: Python 3.9+, the SSM agent and BBR are all in the image.
AMI_PARAMETER = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
SSM_CORE = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
TAGS = [{"Key": "Project", "Value": "satmux"}, {"Key": "ManagedBy", "Value": "jai/agent-pager deploy/satmux"}]
LIVE_STATES = ["pending", "running", "stopping", "stopped"]

ASSUME_EC2 = {
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}],
}


def refused(message: str) -> RuntimeError:
    """A state the action must not change by itself; the message says what to run instead. (The sandbox
    allows no class definitions, so this is a RuntimeError whose message starts with "refused: ".)"""
    return RuntimeError("refused: " + message)


def vpc_resolver(cidr: str) -> str:
    """The Amazon DNS server of a VPC: its network address plus two (172.31.0.0/16 -> 172.31.0.2)."""
    address, bits = cidr.split("/")
    octets = [int(o) for o in address.split(".")]
    value = sum(o << (8 * (3 - i)) for i, o in enumerate(octets))
    network = value & ~((1 << (32 - int(bits))) - 1) & 0xFFFFFFFF
    resolver = network + 2
    return ".".join(str((resolver >> (8 * (3 - i))) & 0xFF) for i in range(4))


def indent(text: str, spaces: int) -> str:
    """Indents every line but the first, for a YAML block whose first line the template already indents."""
    pad = " " * spaces
    return text.rstrip("\n").replace("\n", "\n" + pad)


def render_user_data(cfg: dict[str, Any], resolver: str) -> str:
    """host/cloud-init.yaml with its @NAME@ placeholders filled; the files are host/'s, sent by deploy.sh."""
    files = cfg["files"]
    values = {
        "@PORT@": str(PORT),
        "@PSK_PARAMETER@": PSK_PARAMETER,
        "@MONITOR_TOKEN_PARAMETER@": MONITOR_TOKEN_PARAMETER,
        "@MONITOR_URL@": MONITOR_URL,
        "@EGRESS_ALARM_GB@": str(cfg["egress_alarm_gb"]),
        "@MONITOR_SCRIPT@": indent(files["monitor.sh"], 6),
        "@MONITOR_SERVICE@": indent(files["satmux-monitor.service"], 6),
        "@MONITOR_TIMER@": indent(files["satmux-monitor.timer"], 6),
        "@SATMUX_URL@": f"https://raw.githubusercontent.com/Th0rgal/satmux/{cfg['satmux_commit']}/satmux.py",
        "@SATMUX_SHA256@": cfg["satmux_sha256"],
        "@RUN_SCRIPT@": indent(files["run.sh"], 6),
        "@FETCH_SCRIPT@": indent(files["fetch-psk.sh"], 6),
        "@PSK_SERVICE@": indent(files["satmux-psk.service"], 6),
        "@SATMUX_SERVICE@": indent(files["satmux.service"].replace("@VPC_RESOLVER@", resolver), 6),
    }
    text = files["cloud-init.yaml"]
    for key, value in values.items():
        text = text.replace(key, value)
    left = placeholders(text)
    if left:
        raise ValueError(f"unfilled placeholders in cloud-init: {', '.join(left)}")
    return text


def placeholders(text: str) -> list[str]:
    """Every @NAME@ (capitals, digits and _) left in text."""
    pieces = text.split("@")[1:-1]
    return [f"@{p}@" for p in pieces if p and all(c.isupper() or c.isdigit() or c == "_" for c in p)]


def failed_with(error: Exception, *codes: str) -> bool:
    return any(code in str(error) for code in codes)


async def aws(call: Call, service: str, operation: str, **params: Any) -> dict[str, Any]:
    return await call(service_name=service, operation_name=operation, region_name=REGION, **params)


async def check_account(call: Call, account: str) -> None:
    got = (await aws(call, "sts", "get_caller_identity"))["Account"]
    if got != account:
        raise refused(f"Executor's AWS account is {got}, not FINN staging {account}")


async def ensure_role(call: Call, account: str, log: list[str]) -> bool:
    """The instance role and profile. True when the profile is new (IAM needs a moment before EC2 sees it)."""
    try:
        await aws(call, "iam", "get_role", RoleName=NAME)
    except Exception as error:
        if not failed_with(error, "NoSuchEntity"):
            raise
        await aws(call, "iam", "create_role", RoleName=NAME, AssumeRolePolicyDocument=json.dumps(ASSUME_EC2), Tags=TAGS)
        log.append(f"created role {NAME}")
    await aws(call, "iam", "attach_role_policy", RoleName=NAME, PolicyArn=SSM_CORE)
    read_psk = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "ssm:GetParameter",
                "Resource": [
                    f"arn:aws:ssm:{REGION}:{account}:parameter{name}"
                    for name in (PSK_PARAMETER, MONITOR_TOKEN_PARAMETER)
                ],
            }
        ],
    }
    await aws(
        call, "iam", "put_role_policy", RoleName=NAME, PolicyName="read-satmux-psk", PolicyDocument=json.dumps(read_psk)
    )
    fresh = False
    try:
        profile = (await aws(call, "iam", "get_instance_profile", InstanceProfileName=NAME))["InstanceProfile"]
    except Exception as error:
        if not failed_with(error, "NoSuchEntity"):
            raise
        profile = (await aws(call, "iam", "create_instance_profile", InstanceProfileName=NAME, Tags=TAGS))[
            "InstanceProfile"
        ]
        log.append(f"created instance profile {NAME}")
        fresh = True
    if not any(role["RoleName"] == NAME for role in profile.get("Roles", [])):
        await aws(call, "iam", "add_role_to_instance_profile", InstanceProfileName=NAME, RoleName=NAME)
        fresh = True
    return fresh


async def default_vpc(call: Call) -> dict[str, Any]:
    vpcs = (await aws(call, "ec2", "describe_vpcs", Filters=[{"Name": "isDefault", "Values": ["true"]}]))["Vpcs"]
    if not vpcs:
        raise refused(f"{REGION} has no default VPC")
    return vpcs[0]


async def find_security_group(call: Call, vpc_id: str) -> str | None:
    groups = (
        await aws(
            call,
            "ec2",
            "describe_security_groups",
            Filters=[{"Name": "group-name", "Values": [NAME]}, {"Name": "vpc-id", "Values": [vpc_id]}],
        )
    )["SecurityGroups"]
    return groups[0]["GroupId"] if groups else None


async def ensure_security_group(call: Call, vpc_id: str, log: list[str]) -> str:
    group_id = await find_security_group(call, vpc_id)
    if group_id is None:
        group_id = (
            await aws(
                call,
                "ec2",
                "create_security_group",
                GroupName=NAME,
                Description="satmux carriers on TCP 8444 and 443; no SSH (SSM Session Manager only)",
                VpcId=vpc_id,
                TagSpecifications=[{"ResourceType": "security-group", "Tags": [{"Key": "Name", "Value": NAME}, *TAGS]}],
            )
        )["GroupId"]
        log.append(f"created security group {group_id}")
    for port in (PORT, PUBLIC_PORT):
        await open_port(call, group_id, port, log)
    return group_id


async def open_port(call: Call, group_id: str, port: int, log: list[str]) -> None:
    try:
        await aws(
            call,
            "ec2",
            "authorize_security_group_ingress",
            GroupId=group_id,
            IpPermissions=[
                {
                    "IpProtocol": "tcp",
                    "FromPort": port,
                    "ToPort": port,
                    "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "satmux carriers; PSK-authenticated"}],
                }
            ],
        )
        log.append(f"opened TCP {port}")
    except Exception as error:
        if not failed_with(error, "InvalidPermission.Duplicate"):
            raise


async def find_instance(call: Call) -> dict[str, Any] | None:
    reservations = (
        await aws(
            call,
            "ec2",
            "describe_instances",
            Filters=[{"Name": "tag:Name", "Values": [NAME]}, {"Name": "instance-state-name", "Values": LIVE_STATES}],
        )
    )["Reservations"]
    instances = [i for r in reservations for i in r["Instances"]]
    return instances[0] if instances else None


def tag(resource: dict[str, Any], key: str) -> str | None:
    return next((t["Value"] for t in resource.get("Tags", []) if t["Key"] == key), None)


async def wait_for_state(call: Call, instance_id: str, state: str) -> None:
    for _ in range(100):
        reservations = (await aws(call, "ec2", "describe_instances", InstanceIds=[instance_id]))["Reservations"]
        if reservations[0]["Instances"][0]["State"]["Name"] == state:
            return
        await asyncio.sleep(3)
    raise TimeoutError(f"{instance_id} did not reach {state}")


async def launch(call: Call, cfg: dict[str, Any], group_id: str, user_data: str, fresh_profile: bool) -> str:
    ami = (await aws(call, "ssm", "get_parameter", Name=AMI_PARAMETER))["Parameter"]["Value"]
    tags = [{"Key": "Name", "Value": NAME}, {"Key": "HostFilesSha256", "Value": cfg["host_sha256"]}, *TAGS]
    params: dict[str, Any] = {
        "ImageId": ami,
        "InstanceType": INSTANCE_TYPE,
        "MinCount": 1,
        "MaxCount": 1,
        "IamInstanceProfile": {"Name": NAME},
        "SecurityGroupIds": [group_id],
        "UserData": user_data,
        "MetadataOptions": {"HttpTokens": "required", "HttpPutResponseHopLimit": 1, "HttpEndpoint": "enabled"},
        "BlockDeviceMappings": [
            {
                "DeviceName": "/dev/xvda",
                "Ebs": {"VolumeSize": 8, "VolumeType": "gp3", "Encrypted": True, "DeleteOnTermination": True},
            }
        ],
        "TagSpecifications": [{"ResourceType": "instance", "Tags": tags}, {"ResourceType": "volume", "Tags": tags}],
    }
    # A new instance profile takes a few seconds to reach EC2.
    for attempt in range(8 if fresh_profile else 1):
        try:
            instance = (await aws(call, "ec2", "run_instances", **params))["Instances"][0]
            break
        except Exception as error:
            if (
                not fresh_profile
                or attempt == 7
                or not failed_with(error, "Invalid IAM Instance Profile", "InvalidParameterValue")
            ):
                raise
            await asyncio.sleep(3)
    return str(instance["InstanceId"])


async def ensure_address(call: Call, instance_id: str, log: list[str]) -> str | None:
    """The Elastic IP, attached to the instance; None while the instance is still pending (apply again)."""
    addresses = (await aws(call, "ec2", "describe_addresses", Filters=[{"Name": "tag:Name", "Values": [NAME]}]))[
        "Addresses"
    ]
    if addresses:
        address = addresses[0]
    else:
        address = await aws(
            call,
            "ec2",
            "allocate_address",
            Domain="vpc",
            TagSpecifications=[{"ResourceType": "elastic-ip", "Tags": [{"Key": "Name", "Value": NAME}, *TAGS]}],
        )
        log.append(f"allocated Elastic IP {address['PublicIp']}")
    if address.get("InstanceId") != instance_id:
        try:
            await aws(
                call,
                "ec2",
                "associate_address",
                AllocationId=address["AllocationId"],
                InstanceId=instance_id,
                AllowReassociation=True,
            )
        except Exception as error:
            if failed_with(error, "IncorrectInstanceState", "is not in a valid state"):
                return None
            raise
        log.append(f"associated {address['PublicIp']} with {instance_id}")
    return str(address["PublicIp"])


async def require_parameter(call: Call, name: str) -> None:
    try:
        await aws(call, "ssm", "get_parameter", Name=name)
    except Exception as error:
        if failed_with(error, "ParameterNotFound"):
            raise refused(f"{name} is missing: deploy.sh writes it before apply") from error
        raise


async def apply(call: Call, cfg: dict[str, Any], replace: bool) -> dict[str, Any]:
    log: list[str] = []
    for name in (PSK_PARAMETER, MONITOR_TOKEN_PARAMETER):
        await require_parameter(call, name)
    fresh_profile = await ensure_role(call, cfg["account"], log)
    vpc = await default_vpc(call)
    group_id = await ensure_security_group(call, vpc["VpcId"], log)
    instance = await find_instance(call)
    if instance is not None and tag(instance, "HostFilesSha256") != cfg["host_sha256"]:
        if not replace:
            raise refused(f"{instance['InstanceId']} runs older host files: run `deploy.sh replace` to rebuild it")
        await aws(call, "ec2", "terminate_instances", InstanceIds=[instance["InstanceId"]])
        await wait_for_state(call, instance["InstanceId"], "terminated")
        log.append(f"terminated {instance['InstanceId']} (older host files)")
        instance = None
    if instance is None:
        user_data = render_user_data(cfg, vpc_resolver(vpc["CidrBlock"]))
        instance_id = await launch(call, cfg, group_id, user_data, fresh_profile)
        log.append(f"launched {instance_id}")
    else:
        instance_id = instance["InstanceId"]
    host = await ensure_address(call, instance_id, log)
    if host is None:
        log.append(f"{instance_id} is still pending: apply again")
        return {"pending": True, "instance_id": instance_id, "log": log}
    return {
        "pending": False,
        "host": host,
        "port": PORT,
        "instance_id": instance_id,
        "psk_parameter": PSK_PARAMETER,
        "log": log,
    }


async def status(call: Call) -> dict[str, Any]:
    instance = await find_instance(call)
    if instance is None:
        raise refused("no satmux-relay instance: run `deploy.sh deploy`")
    addresses = (await aws(call, "ec2", "describe_addresses", Filters=[{"Name": "tag:Name", "Values": [NAME]}]))[
        "Addresses"
    ]
    return {
        "host": addresses[0]["PublicIp"] if addresses else None,
        "port": PORT,
        "instance_id": instance["InstanceId"],
        "state": instance["State"]["Name"],
    }


async def run_on_host(call: Call, script: str) -> dict[str, Any]:
    instance_id = (await status(call))["instance_id"]
    command_id = (
        await aws(
            call,
            "ssm",
            "send_command",
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [script]},
        )
    )["Command"]["CommandId"]
    result: dict[str, Any] = {}
    for _ in range(60):
        await asyncio.sleep(2)
        try:
            result = await aws(call, "ssm", "get_command_invocation", CommandId=command_id, InstanceId=instance_id)
        except Exception as error:
            if failed_with(error, "InvocationDoesNotExist"):
                continue
            raise
        if result["Status"] not in ("Pending", "InProgress", "Delayed"):
            break
    return {
        "status": result.get("Status"),
        "stdout": result.get("StandardOutputContent", ""),
        "stderr": result.get("StandardErrorContent", ""),
    }


async def put_secret(call: Call, name: str, value: str) -> dict[str, Any]:
    """Writes the PSK (64 lowercase hex characters) or the monitor check-in bearer (32-512 characters)."""
    if name == PSK_PARAMETER:
        if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise refused("the PSK must be 64 lowercase hex characters")
    elif name == MONITOR_TOKEN_PARAMETER:
        if not 32 <= len(value) <= 512:
            raise refused("a monitor token is 32-512 characters")
    else:
        raise refused(f"relay.py writes only {PSK_PARAMETER} and {MONITOR_TOKEN_PARAMETER}")
    await aws(call, "ssm", "put_parameter", Name=name, Value=value, Type="SecureString", Overwrite=True)
    return {"parameter": name}


async def ignore_missing(step: Awaitable[Any], *codes: str) -> None:
    try:
        await step
    except Exception as error:
        if not failed_with(error, *codes):
            raise


async def destroy(call: Call) -> dict[str, Any]:
    log: list[str] = []
    for address in (await aws(call, "ec2", "describe_addresses", Filters=[{"Name": "tag:Name", "Values": [NAME]}]))[
        "Addresses"
    ]:
        if address.get("AssociationId"):
            await aws(call, "ec2", "disassociate_address", AssociationId=address["AssociationId"])
        await aws(call, "ec2", "release_address", AllocationId=address["AllocationId"])
        log.append(f"released {address['PublicIp']}")
    instance = await find_instance(call)
    if instance is not None:
        await aws(call, "ec2", "terminate_instances", InstanceIds=[instance["InstanceId"]])
        await wait_for_state(call, instance["InstanceId"], "terminated")
        log.append(f"terminated {instance['InstanceId']}")
    group_id = await find_security_group(call, (await default_vpc(call))["VpcId"])
    if group_id is not None:
        for attempt in range(20):
            try:
                await aws(call, "ec2", "delete_security_group", GroupId=group_id)
                log.append(f"deleted security group {group_id}")
                break
            except Exception as error:
                if attempt == 19 or not failed_with(error, "DependencyViolation"):
                    raise
                await asyncio.sleep(5)
    await ignore_missing(
        aws(call, "iam", "remove_role_from_instance_profile", InstanceProfileName=NAME, RoleName=NAME), "NoSuchEntity"
    )
    await ignore_missing(aws(call, "iam", "delete_instance_profile", InstanceProfileName=NAME), "NoSuchEntity")
    await ignore_missing(aws(call, "iam", "detach_role_policy", RoleName=NAME, PolicyArn=SSM_CORE), "NoSuchEntity")
    await ignore_missing(
        aws(call, "iam", "delete_role_policy", RoleName=NAME, PolicyName="read-satmux-psk"), "NoSuchEntity"
    )
    await ignore_missing(aws(call, "iam", "delete_role", RoleName=NAME), "NoSuchEntity")
    for name in (PSK_PARAMETER, MONITOR_TOKEN_PARAMETER):
        await ignore_missing(aws(call, "ssm", "delete_parameter", Name=name), "ParameterNotFound")
    log.append("deleted the role, the instance profile, the key and the monitor token")
    return {"log": log}


async def main(call: Call, action: str, cfg: dict[str, Any]) -> None:
    try:
        await check_account(call, cfg["account"])
        if action == "apply":
            result = await apply(call, cfg, replace=False)
        elif action == "replace":
            result = await apply(call, cfg, replace=True)
        elif action == "status":
            result = await status(call)
        elif action == "run":
            result = await run_on_host(call, cfg["script"])
        elif action == "put-secret":
            result = await put_secret(call, cfg["name"], cfg["value"])
        elif action == "destroy":
            result = await destroy(call)
        else:
            raise refused(f"unknown action {action}")
        print("RESULT " + json.dumps({"ok": True, **result}))
    except RuntimeError as error:
        if not str(error).startswith("refused: "):
            raise
        print("RESULT " + json.dumps({"ok": False, "error": str(error).removeprefix("refused: ")}))
