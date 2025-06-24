provider "aws" {
  region = local.region
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

locals {
  #   name   = "ex-${basename(path.cwd)}"
  #   region = "eu-west-1"
  name   = var.name
  region = var.region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.1"

  cluster_name    = local.name
  cluster_version = "1.32"

  # Gives Terraform identity admin access to cluster which will
  # allow deploying resources (Karpenter) into the cluster
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets



  eks_managed_node_groups = {
    karpenter = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 2

        labels = {
          # Used to ensure Karpenter runs on nodes that it does not manage
          "karpenter.sh/controller" = "true"
        }

      tags = {
        "karpenter.sh/discovery" = var.name
      }
    }
  }

#   node_security_group_additional_rules = {
#     ingress_self_all = {
#       description = "Node to node all ports/protocols"
#       protocol    = "-1"
#       from_port   = 0
#       to_port     = 0
#       type        = "ingress"
#       self        = true
#     }
#   }

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}

module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  cluster_name                    = module.eks.cluster_name
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  create_iam_role = false
  tags            = local.tags
}

################################################################################
# Karpenter
################################################################################

# module "karpenter" {
#   source = "terraform-aws-modules/eks/aws//modules/karpenter"
#   #   version = "20.37.1"

#   # #   cluster_name          = module.eks.cluster_name
#   #   enable_v1_permissions = true

#   #   # Name needs to match role name passed to the EC2NodeClass
#   #   node_iam_role_use_name_prefix   = false
#   #   node_iam_role_name              = local.name
#   #   create_pod_identity_association = true

#   #   # Used to attach additional IAM policies to the Karpenter node IAM role
#   create_node_iam_role = false
#   node_iam_role_arn    = module.eks.eks_managed_node_groups["karpenter"].iam_role_arn

#   # Since the node group role will already have an access entry
#   create_access_entry = false

#   #   tags = local.tags
#   # }

#   # module "karpenter_disabled" {
#   #   source  = "terraform-aws-modules/eks/aws//examples/karpenter"
#   #   version = "20.37.1"


#   #   create = false

#   tags = {
#     Environment = "karpenter"
#     Terraform   = "true"
#   }
# }

################################################################################
# Karpenter Helm chart & manifests
# Not required; just to demonstrate functionality of the sub-module
################################################################################

# resource "helm_release" "karpenter" {
#   namespace           = "kube-system"
#   name                = "karpenter"
#   repository          = "oci://public.ecr.aws/karpenter"
#   repository_username = data.aws_ecrpublic_authorization_token.token.user_name
#   repository_password = data.aws_ecrpublic_authorization_token.token.password
#   chart               = "karpenter"
#   version             = "1.1.1"
#   wait                = false

#   values = [
#     <<-EOT
#     nodeSelector:
#       karpenter.sh/controller: 'true'
#     dnsPolicy: Default
#     settings:
#       clusterName: ${module.eks.cluster_name}
#       clusterEndpoint: ${module.eks.cluster_endpoint}
#       interruptionQueue: ${module.karpenter.queue_name}
#     webhook:
#       enabled: false
#     EOT
#   ]
# }

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}

# resource "aws_iam_role" "karpenter" {
#   name = "karpenter-node-role"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect = "Allow"
#       Principal = {
#         Service = "ec2.amazonaws.com"
#       }
#       Action = "sts:AssumeRole"
#     }]
#   })

#   managed_policy_arns = [
#     "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
#     "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
#     "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
#     "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess",
#     "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
#   ]

#   tags = {
#     Name = "karpenter-node-role"
#   }
# }


resource "aws_iam_role" "karpenter" {
  name = "karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess",
    "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
  ]
}

data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "karpenter_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
  }
}

resource "aws_iam_instance_profile" "karpenter" {
  name = "karpenter-node-instance-profile"
  role = aws_iam_role.karpenter.name
}


# resource "helm_release" "karpenter_crd" {
#   depends_on = [module.eks]
#   namespace        = "karpenter"
#   create_namespace = true

#   name                = "karpenter-crd"
#   repository          = "oci://public.ecr.aws/karpenter"
#   chart               = "karpenter-crd"
#   version             = "v0.32.1"
#   replace             = true
#   force_update        = true

# }

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.5.0"

  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password

  namespace        = "karpenter"
  create_namespace = true
  skip_crds        = true

  set = [
    {
      name  = "settings.clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "settings.clusterEndpoint"
      value = module.eks.cluster_endpoint
    },
    {
      name  = "settings.aws.defaultInstanceProfile"
      value = aws_iam_instance_profile.karpenter.name
    },
    {
      name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.karpenter.arn
    },
    {
      name  = "serviceAccount.name"
      value = "karpenter"
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.karpenter_controller.arn
    }
  ]

  depends_on = [module.eks,
    kubernetes_namespace.karpenter,
  kubernetes_service_account.karpenter]
}



resource "helm_release" "karpenter_crd" {
  depends_on       = [module.eks]
  namespace        = "karpenter"
  create_namespace = true

  name         = "karpenter-crd"
  repository   = "oci://public.ecr.aws/karpenter"
  chart        = "karpenter-crd"
  version      = "1.5.0"
  replace      = true
  force_update = true
  skip_crds    = false

  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password

  set = [
    {
      name  = "settings.clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "settings.clusterEndpoint"
      value = module.eks.cluster_endpoint
    },
    {
      name  = "settings.aws.defaultInstanceProfile"
      value = aws_iam_instance_profile.karpenter.name
    },
    {
      name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.karpenter.arn
    }
  ]
}
resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
  }
}

resource "kubernetes_service_account" "karpenter" {
  metadata {
    name      = "karpenter"
    namespace = "karpenter"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
    }
  }
  depends_on = [module.eks, kubernetes_namespace.karpenter]
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "karpenter-controller-policy"
  description = "Permissions for Karpenter Controller"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:DeleteLaunchTemplate",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "pricing:GetProducts",
          "ssm:GetParameter"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = "iam:CreateServiceLinkedRole",
        Resource = "*",
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "spot.amazonaws.com"
          }
        }
      },
      {
        Effect   = "Allow",
        Action   = "iam:PassRole",
        Resource = "*",
        Condition = {
          StringEqualsIfExists = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "karpenter_attach" {
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

resource "aws_iam_role" "karpenter_controller" {
  name = "karpenter-controller-role"

  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role_policy.json

  managed_policy_arns = [
    aws_iam_policy.karpenter_controller.arn
  ]
}

# resource "helm_release" "karpenter_provider_aws" {
#   name       = "karpenter"
#   namespace  = "karpenter"

#   repository = "oci://public.ecr.aws/karpenter"
#   chart      = "karpenter"
#   version    = "v1.5.0"

#   repository_username = data.aws_ecrpublic_authorization_token.token.user_name
#   repository_password = data.aws_ecrpublic_authorization_token.token.password

#   set = [
#     {
#       name  = "settings.clusterName"
#       value = module.eks.cluster_name
#     },
#     {
#       name  = "settings.clusterEndpoint"
#       value = module.eks.cluster_endpoint
#     },
#     {
#       name  = "settings.aws.defaultInstanceProfile"
#       value = aws_iam_instance_profile.karpenter.name
#     },
#     {
#       name  = "serviceAccount.create"
#       value = "false"
#     }
#   ]

#   depends_on = [
#     helm_release.karpenter_crd,
#     kubernetes_service_account.karpenter,
#   ]
# }
