#!/bin/bash
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# Script to deploy the ledgermonolith service on a GCE VM
# Will delete and recreate any existing ledgermonolith VM

if [[ -z ${PROJECT_ID} ]]; then
  echo "PROJECT_ID must be set"
  exit 0
elif [[ -z ${ZONE} ]]; then
  echo "ZONE must be set"
  exit 0
elif [[ -z ${CLUSTER} ]]; then
  echo "CLUSTER must be set"
  exit 0
else
  echo "PROJECT_ID: ${PROJECT_ID}"
  echo "ZONE: ${ZONE}"
  echo "CLUSTER: ${CLUSTER}"
fi


# Google Cloud Storage bucket to pull build artifacts from
if [[ -z ${GCS_BUCKET} ]]; then
  # If no bucket specified, default to canonical build artifacts
  GCS_BUCKET=bank-of-anthos
  echo "GCS_BUCKET not specified, defaulting to canonical pre-built artifacts..."
fi
echo "GCS_BUCKET: ${GCS_BUCKET}"

# Target subnetwork for Ledger Monolith VM
if [[ -z ${VM_SUBNET} ]]; then
  # If no subnet specified, default to default subnet
  VM_SUBNET=default
  echo "Subnet not specified, defaulting to default subnetwork..."
fi
echo "VM_SUBNET: ${VM_SUBNET}"


CWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"


# If the monolith VM already exists, delete it to start fresh
echo "Cleaning up VM if it already exists..."
gcloud compute instances describe ledgermonolith-service \
    --project $PROJECT_ID \
    --zone $ZONE \
    --quiet >/dev/null 2>&1
if [ $? -eq 0 ]; then
  gcloud compute instances delete ledgermonolith-service \
      --project $PROJECT_ID \
      --zone $ZONE \
      --delete-disks all \
      --quiet
fi


# Create the monolith VM
echo "Creating GCE instance..."
gcloud compute instances create ledgermonolith-service \
    --project $PROJECT_ID \
    --zone $ZONE \
    --subnet=$VM_SUBNET \
    --image-family=debian-10 \
    --image-project=debian-cloud \
    --machine-type=n1-standard-1 \
    --scopes cloud-platform,storage-ro \
    --metadata gcs-bucket=${GCS_BUCKET},VmDnsSetting=ZonalPreferred \
    --metadata-from-file startup-script=${CWD}/../init/install-script.sh \
    --tags monolith \
    --quiet

# Create firewall rule to allow access to the monolith via IAP
echo "Creating IAP firewall rule..."
gcloud compute firewall-rules create monolith-allow-ssh \
    --project $PROJECT_ID  \
    --direction=INGRESS \
    --priority=1000 \
    --network=prod-gcp-vpc-01 \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=monolith

# Grant user IAP Tunnel Resource Accessor role
echo "Granting IAP Tunnel Resource Accessor role..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member=user:$GCLOUD_USER \
    --role=roles/iap.tunnelResourceAccessor

# Create Cymbal Bank's Kubernetes Service Account
kubectl create serviceaccount --namespace default cymbal-bank-sa

# Create Cymbal Bank's GCP Service Account
gcloud iam service-accounts create cymbal-bank-sa

# Assign Workload Identity role to GCP Service Account
gcloud iam service-accounts add-iam-policy-binding \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[default/cymbal-bank-sa]" \
  cymbal-bank-sa@${PROJECT_ID}.iam.gserviceaccount.com

# Annotate Kubernetes Service Account
kubectl annotate serviceaccount \
  --namespace default \
  cymbal-bank-sa \
  iam.gke.io/gcp-service-account=cymbal-bank-sa@${PROJECT_ID}.iam.gserviceaccount.com

# Add IAM Roles to GCP Service Account
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member=serviceAccount:cymbal-bank-sa@${PROJECT_ID}.iam.gserviceaccount.com \
    --role=roles/cloudtrace.agent

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member=serviceAccount:cymbal-bank-sa@${PROJECT_ID}.iam.gserviceaccount.com \
    --role=roles/logging.logWriter

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member=serviceAccount:cymbal-bank-sa@${PROJECT_ID}.iam.gserviceaccount.com \
    --role=roles/monitoring.metricWriter

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member=serviceAccount:cymbal-bank-sa@${PROJECT_ID}.iam.gserviceaccount.com \
    --role=roles/monitoring.viewer

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member=serviceAccount:cymbal-bank-sa@${PROJECT_ID}.iam.gserviceaccount.com \
    --role=roles/stackdriver.resourceMetadata.writer
