#!/bin/bash

# ============================================================
# delete-all-stacks.sh  —  DESTROY WITH CARE
# - Logs to ./delete-logs
# - Verifies AWS identity
# - Interactive stack deletion (dependency-aware via Exports/Imports)
# - Handles termination protection + waiters
# - ALWAYS runs a deep sweep for orphaned billable resources
#   (EC2 instances/EBS/EIPs/NAT/ALBs, VPC endpoints, RDS, S3, Glue,
#    Location Service, KMS CMKs, SNS)
# - Safe prompts before the riskiest ops (e.g., emptying S3 buckets,
#   deleting RDS without snapshots, scheduling KMS key deletion)
# ============================================================

set -u
set -o pipefail

# === CREATE LOG FOLDER AND FILE ===
LOG_DIR="./logs/delete-all-stacks"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/delete-log-$TIMESTAMP.txt"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "📜 Logging to $LOG_FILE"

# === AWS ACCOUNT SAFETY CHECK ===
echo "🔒 Checking AWS identity..."

if ! account_id=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
  echo "❌ Could not get AWS identity. Are your credentials configured?"
  exit 1
fi
user_arn=$(aws sts get-caller-identity --query "Arn" --output text)
caller_user=$(echo "$user_arn" | sed 's/^.*\///')
region=$(aws configure get region)
region=${region:-"us-east-1"}
export AWS_DEFAULT_REGION="$region"     ### NEW: ensure every CLI call uses this region

echo "🚨 You are logged in as:"
echo "👤 User:       $caller_user"
echo "🔗 ARN:        $user_arn"
echo "🏢 Account ID: $account_id"
echo "🌍 Region:     $region"
echo ""

read -p "❓ Is this the right account to wreak havoc on? (y/N): " confirm_account
if [[ "${confirm_account:-N}" != [yY] ]]; then
  echo "🛑 Good call. Destruction postponed."
  exit 1
fi

# === LIST STACKS ===
echo "🕵️ Scanning for active CloudFormation stacks..."

if ! all_stacks=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[*].StackName" --output text 2>/dev/null); then
  echo "❌ Failed to list stacks. Check your permissions."
  all_stacks=""
fi

if [ -z "${all_stacks}" ]; then
  echo "🎉 No active stacks found."
  echo "➡️  Proceeding directly to orphaned resource sweep... (important!)"   ### NEW
else
  echo "🧨 Here are your active stacks:"
  i=1
  declare -a stack_options
  for stack in $all_stacks; do
    echo " [$i] 💣 $stack"
    stack_options[$i]=$stack
    ((i++))
  done

  echo ""
  read -rp "🔢 Enter the numbers of the stacks you want to delete (e.g., 1 3 4), or press Enter to skip stack deletion: " selection

  declare -a selected_stacks
  for num in $selection; do
    if [[ "$num" =~ ^[0-9]+$ ]] && [[ -n "${stack_options[$num]:-}" ]]; then
      selected_stacks+=("${stack_options[$num]}")
    else
      echo "⚠️ Invalid selection: '$num'. Skipping."
    fi
  done

  if [ "${#selected_stacks[@]}" -gt 0 ]; then
    echo "⚠️ You selected the following stacks for deletion:"
    for s in "${selected_stacks[@]}"; do
      echo "   💥 $s"
    done
    echo ""

    read -p "🚨 Final confirmation — delete these stacks? (y/N): " confirm_delete
    if [[ "${confirm_delete:-N}" != [yY] ]]; then
      echo "🙅‍♂️ Operation cancelled. Skipping stack deletion."
      selected_stacks=()
    fi
  fi

  if [ "${#selected_stacks[@]}" -gt 0 ]; then
    # === UTILS ===
    contains_name() {
      local needle="$1"; shift
      for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
      return 1
    }

    # === MAP SELECTED STACK NAMES <-> IDS ===
    declare -A id_by_name
    declare -A name_by_id
    echo "🧭 Resolving StackIds for selected stacks..."
    for s in "${selected_stacks[@]}"; do
      sid=$(aws cloudformation describe-stacks --stack-name "$s" --query "Stacks[0].StackId" --output text 2>/dev/null)
      if [ -z "$sid" ] || [[ "$sid" == "None" ]]; then
        echo "❌ Could not resolve StackId for $s. Skipping."
        continue
      fi
      id_by_name["$s"]="$sid"
      name_by_id["$sid"]="$s"
    done

    filtered=()
    for s in "${selected_stacks[@]}"; do
      [ -n "${id_by_name[$s]:-}" ] && filtered+=("$s")
    done
    selected_stacks=("${filtered[@]}")

    if [ "${#selected_stacks[@]}" -eq 0 ]; then
      echo "❌ No resolvable stacks remain. Skipping stack deletion."
    else
      # === BUILD DEPENDENCY GRAPH ===
      declare -A deps_incoming
      echo "🧠 Analyzing stack dependencies (Exports/Imports)..."
      declare -A selected_id_set; for s in "${selected_stacks[@]}"; do selected_id_set["${id_by_name[$s]}"]=1; endone=true; done

      tmp_exports_file="$(mktemp)"
      aws cloudformation list-exports --query "Exports[].{Id:ExportingStackId,Name:Name}" --output text > "$tmp_exports_file" 2>/dev/null || true

      if [ -s "$tmp_exports_file" ]; then
        while IFS=$'\t' read -r exp_id exp_name; do
          if [ -n "${selected_id_set[$exp_id]:-}" ]; then
            importers=$(aws cloudformation list-imports --export-name "$exp_name" --query "Imports" --output text 2>/dev/null || true)
            if [ -n "$importers" ]; then
              for importer_id in $importers; do
                importer_name="${name_by_id[$importer_id]:-}"
                exporter_name="${name_by_id[$exp_id]:-}"
                if [ -n "$importer_name" ] && [ -n "$exporter_name" ]; then
                  current="${deps_incoming[$importer_name]:-}"
                  [[ " $current " != *" $exporter_name "* ]] && deps_incoming["$importer_name"]="${current:+$current }$exporter_name"
                fi
              done
            fi
          fi
        done < "$tmp_exports_file"
      fi
      rm -f "$tmp_exports_file"

      # === TOPO ORDER (importers first) ===
      ordered=(); pending=("${selected_stacks[@]}")
      while [ "${#pending[@]}" -gt 0 ]; do
        progressed=false; next_pending=()
        for s in "${pending[@]}"; do
          if [ -z "${deps_incoming[$s]:-}" ]; then
            ordered+=("$s"); progressed=true
            for k in "${!deps_incoming[@]}"; do
              deps_incoming[$k]=$(echo " ${deps_incoming[$k]} " | sed "s/ $s / /g" | xargs || true)
              [[ "${deps_incoming[$k]}" == "" ]] && unset 'deps_incoming[$k]'
            done
          else
            next_pending+=("$s")
          fi
        done
        if ! $progressed; then ordered+=("${next_pending[@]}"); break; fi
        pending=("${next_pending[@]}")
      done

      echo "🗺️ Deletion order (importers → exporters):"
      for s in "${ordered[@]}"; do echo "   💥 $s"; done

      echo "⏳ Initiating deletions in the computed order..."
      for stack in "${ordered[@]}"; do
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🛡️ Checking termination protection for: $stack ..."
        tp=$(aws cloudformation describe-stacks --stack-name "$stack" --query "Stacks[0].EnableTerminationProtection" --output text 2>/dev/null || echo "False")
        if [ "$tp" == "True" ]; then
          read -p "⚠️  Termination protection is ON for $stack. Disable and proceed? (y/N): " ans
          if [[ "${ans:-N}" =~ ^[yY]$ ]]; then
            aws cloudformation update-termination-protection --stack-name "$stack" --no-enable-termination-protection || { echo "❌ Failed. Skipping."; continue; }
            echo "🛡️ Termination protection disabled."
          else
            echo "⏭️ Skipping $stack due to termination protection."; continue
          fi
        fi

        echo "🗑️ Initiating deletion of stack: $stack ..."
        aws cloudformation delete-stack --stack-name "$stack" || { echo "❌ Delete call failed for $stack."; continue; }

        echo "⏳ Waiting for $stack to be deleted..."
        if aws cloudformation wait stack-delete-complete --stack-name "$stack"; then
          echo "✅ Stack $stack deleted."
        else
          st=$(aws cloudformation describe-stacks --stack-name "$stack" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "unknown")
          reason=$(aws cloudformation describe-stack-events --stack-name "$stack" --query "StackEvents[?ResourceStatus=='DELETE_FAILED']|[0].ResourceStatusReason" --output text 2>/dev/null || true)
          echo "❌ Deletion did not complete for $stack. Status: $st"
          [ -n "$reason" ] && [ "$reason" != "None" ] && echo "   Reason: $reason"
        fi
      done
    fi
  fi
fi

# ------------------------------------------------------------------
#                       ORPHANED RESOURCES SWEEP
# ------------------------------------------------------------------

confirm() { read -p "$1 (y/N): " _a; [[ "${_a:-N}" =~ ^[yY]$ ]]; }

echo ""
echo "🧹 Starting orphaned resource sweep (these often incur charges)."

# --- EC2 Instances (on-demand charges) ---
inst_ids=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
if [ -n "$inst_ids" ]; then
  echo "🖥️ EC2 instances found: $inst_ids"
  if confirm "   ➤ Terminate ALL of these EC2 instances?"; then
    aws ec2 terminate-instances --instance-ids $inst_ids || echo "⚠️ Terminate call failed."
  fi
else
  echo "✅ No EC2 instances."
fi

# --- NAT Gateways (costly) ---
nat_ids=$(aws ec2 describe-nat-gateways --query "NatGateways[?State!='deleted'].NatGatewayId" --output text 2>/dev/null || true)
if [ -n "$nat_ids" ]; then
  echo "🚪 NAT Gateways: $nat_ids"
  if confirm "   ➤ Delete ALL NAT Gateways?"; then
    for nat in $nat_ids; do aws ec2 delete-nat-gateway --nat-gateway-id "$nat" || echo "⚠️ Could not delete NAT $nat"; done
  fi
else
  echo "✅ No NAT Gateways."
fi

# --- Elastic IPs (charged when unattached) ---
eips=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text 2>/dev/null || true)
if [ -n "$eips" ]; then
  echo "📡 Elastic IPs: $eips"
  if confirm "   ➤ Release ALL Elastic IPs?"; then
    for eip in $eips; do aws ec2 release-address --allocation-id "$eip" || echo "⚠️ Could not release EIP $eip"; done
  fi
else
  echo "✅ No Elastic IPs."
fi

# --- Unattached EBS Volumes ---
vols=$(aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId" --output text 2>/dev/null || true)
if [ -n "$vols" ]; then
  echo "💽 Unattached EBS volumes: $vols"
  if confirm "   ➤ Delete ALL unattached EBS volumes?"; then
    for v in $vols; do aws ec2 delete-volume --volume-id "$v" || echo "⚠️ Could not delete volume $v"; done
  fi
else
  echo "✅ No unattached EBS volumes."
fi

# --- Load Balancers (ALB/NLB) ---
lbs=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null || true)
if [ -n "$lbs" ]; then
  echo "⚖️ Load balancers: $lbs"
  if confirm "   ➤ Delete ALL load balancers?"; then
    for lb in $lbs; do aws elbv2 delete-load-balancer --load-balancer-arn "$lb" || echo "⚠️ Could not delete LB $lb"; done
  fi
else
  echo "✅ No load balancers."
fi

# --- VPC Endpoints (EC2-Other charges) ---
vpc_endpoints=$(aws ec2 describe-vpc-endpoints --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)
if [ -n "$vpc_endpoints" ]; then
  echo "🧩 VPC Endpoints: $vpc_endpoints"
  if confirm "   ➤ Delete ALL VPC endpoints?"; then
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $vpc_endpoints || echo "⚠️ Could not delete some endpoints."
  fi
else
  echo "✅ No VPC endpoints."
fi

# --- RDS instances & snapshots ---
rds_ids=$(aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output text 2>/dev/null || true)
if [ -n "$rds_ids" ]; then
  echo "🗄️ RDS instances: $rds_ids"
  if confirm "   ➤ DELETE ALL RDS instances (skip final snapshot)?"; then
    for r in $rds_ids; do
      # Check deletion protection
      dp=$(aws rds describe-db-instances --db-instance-identifier "$r" \
            --query "DBInstances[0].DeletionProtection" --output text 2>/dev/null || echo "False")
      if [ "$dp" == "True" ]; then
        echo "   🔐 Deletion protection is ON for $r."
        if confirm "      ➤ Disable deletion protection on $r and continue?"; then
          aws rds modify-db-instance --db-instance-identifier "$r" \
            --no-deletion-protection --apply-immediately || { echo "      ⚠️ Failed to disable protection on $r"; continue; }
        else
          echo "      ⏭️ Skipping $r"; continue
        fi
      fi

      # Delete
      aws rds delete-db-instance --db-instance-identifier "$r" --skip-final-snapshot \
        || { echo "      ⚠️ Failed to delete RDS $r"; continue; }
      echo "      ⏳ Waiting for $r to be deleted..."
      aws rds wait db-instance-deleted --db-instance-identifier "$r" || echo "      ⚠️ Waiter failed for $r"
    done
  fi
else
  echo "✅ No RDS instances."
fi

# Manual snapshots (remain billable)
rds_snaps=$(aws rds describe-db-snapshots --snapshot-type manual \
             --query "DBSnapshots[].DBSnapshotIdentifier" --output text 2>/dev/null || true)
if [ -n "$rds_snaps" ]; then
  echo "📸 RDS manual snapshots: $rds_snaps"
  if confirm "   ➤ Delete ALL manual RDS snapshots?"; then
    for s in $rds_snaps; do aws rds delete-db-snapshot --db-snapshot-identifier "$s" || echo "⚠️ Failed to delete snapshot $s"; done
  fi
else
  echo "✅ No manual RDS snapshots."
fi

# --- S3 buckets (storage + requests; careful!) ---
buckets=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null || true)
if [ -n "$buckets" ]; then
  echo "🪣 S3 buckets found."
  if confirm "   ➤ EMPTY & DELETE ALL S3 buckets? (dangerous)"; then
    for b in $buckets; do
      echo "   • $b"
      # Try multi-region delete via s3 rm (handles versions, too)
      aws s3 rb "s3://$b" --force || {
        echo "     Falling back to explicit versioned delete for $b"
        # delete all versions (if versioned)
        vers=$(aws s3api list-object-versions --bucket "$b" --query '[Versions[].{Key:Key,Id:VersionId},DeleteMarkers[].{Key:Key,Id:VersionId}]' --output json 2>/dev/null)
        if [ -n "$vers" ] && [ "$vers" != "null" ]; then
          echo "$vers" | jq -r '.[]|.[]|"\(.Key) \(.Id)"' 2>/dev/null | while read -r key vid; do
            aws s3api delete-object --bucket "$b" --key "$key" --version-id "$vid" || true
          done
        fi
        aws s3api delete-bucket --bucket "$b" || true
      }
    done
  fi
else
  echo "✅ No S3 buckets."
fi

# --- Glue (jobs/crawlers/databases/connections) ---
glue_jobs=$(aws glue list-jobs --query "JobNames[]" --output text 2>/dev/null || true)
glue_crawlers=$(aws glue list-crawlers --query "CrawlerNames[]" --output text 2>/dev/null || true)
glue_dbs=$(aws glue get-databases --query "DatabaseList[].Name" --output text 2>/dev/null || true)
glue_conns=$(aws glue get-connections --query "ConnectionList[].Name" --output text 2>/dev/null || true)

if [ -n "$glue_jobs$glue_crawlers$glue_dbs$glue_conns" ]; then
  echo "🧪 Glue resources detected."
  if confirm "   ➤ Delete ALL Glue jobs/crawlers/databases/connections?"; then
    for j in $glue_jobs; do aws glue delete-job --job-name "$j" || true; done
    for c in $glue_crawlers; do aws glue delete-crawler --name "$c" || true; done
    for d in $glue_dbs; do aws glue delete-database --name "$d" || true; done
    for cn in $glue_conns; do aws glue delete-connection --connection-name "$cn" || true; done
  fi
else
  echo "✅ No Glue resources."
fi

# --- Amazon Location Service (maps, trackers, geofences, places, routes) ---
loc_maps=$(aws location list-maps --query "Entries[].MapName" --output text 2>/dev/null || true)
loc_trackers=$(aws location list-trackers --query "Entries[].TrackerName" --output text 2>/dev/null || true)
loc_geos=$(aws location list-geofence-collections --query "Entries[].CollectionName" --output text 2>/dev/null || true)
loc_places=$(aws location list-place-indexes --query "Entries[].IndexName" --output text 2>/dev/null || true)
loc_routes=$(aws location list-route-calculators --query "Entries[].CalculatorName" --output text 2>/dev/null || true)

if [ -n "$loc_maps$loc_trackers$loc_geos$loc_places$loc_routes" ]; then
  echo "🗺️ Amazon Location resources detected."
  if confirm "   ➤ Delete ALL Location Service resources?"; then
    for x in $loc_maps; do aws location delete-map --map-name "$x" || true; done
    for x in $loc_trackers; do aws location delete-tracker --tracker-name "$x" || true; done
    for x in $loc_geos; do aws location delete-geofence-collection --collection-name "$x" || true; done
    for x in $loc_places; do aws location delete-place-index --index-name "$x" || true; done
    for x in $loc_routes; do aws location delete-route-calculator --calculator-name "$x" || true; done
  fi
else
  echo "✅ No Amazon Location resources."
fi

# --- KMS (customer-managed keys) ---
kms_keys=$(aws kms list-keys --query "Keys[].KeyId" --output text 2>/dev/null || true)
cust_kms=""
for k in $kms_keys; do
  mgr=$(aws kms describe-key --key-id "$k" --query "KeyMetadata.KeyManager" --output text 2>/dev/null || echo "")
  [[ "$mgr" == "CUSTOMER" ]] && cust_kms="$cust_kms $k"
done
if [ -n "$cust_kms" ]; then
  echo "🔑 Customer-managed KMS keys: $cust_kms"
  if confirm "   ➤ SCHEDULE 7-day deletion for ALL these KMS keys? (keys must be disabled first)"; then
    for k in $cust_kms; do
      aws kms disable-key --key-id "$k" 2>/dev/null || true
      aws kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7 || echo "⚠️ Could not schedule deletion for $k"
    done
  fi
else
  echo "✅ No customer-managed KMS keys."
fi

# --- SNS topics ---
sns_topics=$(aws sns list-topics --query "Topics[].TopicArn" --output text 2>/dev/null || true)
if [ -n "$sns_topics" ]; then
  echo "🔔 SNS topics: $sns_topics"
  if confirm "   ➤ Delete ALL SNS topics? (subs go away too)"; then
    for t in $sns_topics; do aws sns delete-topic --topic-arn "$t" || true; done
  fi
else
  echo "✅ No SNS topics."
fi

echo ""
echo "🎯 Sweep complete. Re-run the script until it finds nothing. Keep an eye on Cost Explorer for the next day to confirm charges drop."