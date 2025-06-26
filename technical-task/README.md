# EKS + Karpenter Terraform Setup

This Terraform module provisions an EKS cluster integrated with [Karpenter](https://karpenter.sh/) to enable dynamic scaling using x86 (amd64) and Graviton (arm64) EC2 instances.

## Getting Started

Clone the repo and navigate to the Terraform module:

```bash
git clone https://github.com/paulus01/opsfleet-test-task.git
cd opsfleet-test-task/technical-task/modules
```

Initialize and apply the Terraform configuration:

```bash
terraform init
terraform apply -var-file="../environments/test.tfvars" -auto-approve
```

## Testing Karpenter Node Provisioning

To test Karpenter scheduling on amd64 and arm64 architectures, run the following:

```bash
kubectl apply -f ../test_deploy/testamd64.yaml
kubectl apply -f ../test_deploy/testarm64.yaml
```

These will trigger Karpenter to launch instances that match the specified architecture.

## Example: Pod with Node Selector

You can manually deploy a pod to a specific architecture by setting the `nodeSelector`:

### For **amd64**:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: amd64-test
spec:
  nodeSelector:
    kubernetes.io/arch: amd64
  containers:
    - name: pause
      image: public.ecr.aws/eks-distro/kubernetes/pause:3.9
```

### For **arm64**:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: arm64-test
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
  containers:
    - name: pause
      image: public.ecr.aws/eks-distro/kubernetes/pause:3.9
```

Karpenter will provision the required instance type dynamically based on the architecture specified.