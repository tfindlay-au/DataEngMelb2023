terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.27.0"
    }
  }
}

locals {
  # Source topics for incoming events
  source_topic_names = [
    "input-topic",
    "output-topic"
  ]
}

//------------------------------------------------
// Define an environment to which a cluster belongs

resource "confluent_environment" "demo" {
  display_name = "Demo"
}

//------------------------------------------------
// Define an cluster

resource "confluent_kafka_cluster" "cluster" {
  display_name = "Cluster"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "ap-southeast-2"
  basic {}

  environment {
    id = confluent_environment.demo.id
  }
}

//------------------------------------------------
// Define an schema registry

data "confluent_schema_registry_region" "sr_region" {
  cloud   = "AWS"
  region  = "ap-southeast-2"
  package = "ESSENTIALS"
}

resource "confluent_schema_registry_cluster" "essentials" {
  package = data.confluent_schema_registry_region.sr_region.package

  environment {
    id = confluent_environment.demo.id
  }

  region {
    id = data.confluent_schema_registry_region.sr_region.id
  }
}

//------------------------------------------------
// Define an cluster admin service account

resource "confluent_service_account" "cluster_sa" {
  display_name = "cluster_sa"
  description  = "Service account to manage '${confluent_kafka_cluster.cluster.display_name}' kafka cluster"
}

resource "confluent_role_binding" "kafka_cluster_admin" {
  principal   = "User:${confluent_service_account.cluster_sa.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.cluster.rbac_crn
}

resource "confluent_api_key" "kafka_api_key" {
  display_name = "cluster-api-key"
  description  = "Kafka API Key that is owned by '${confluent_service_account.cluster_sa.display_name}' service account"
  owner {
    id          = confluent_service_account.cluster_sa.id
    api_version = confluent_service_account.cluster_sa.api_version
    kind        = confluent_service_account.cluster_sa.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.cluster.id
    api_version = confluent_kafka_cluster.cluster.api_version
    kind        = confluent_kafka_cluster.cluster.kind

    environment {
      id = confluent_environment.demo.id
    }
  }

  depends_on = [
    confluent_role_binding.kafka_cluster_admin
  ]
}

//------------------------------------------------
// Define topics to hold events

resource "confluent_kafka_topic" "topic" {
  for_each = toset(local.source_topic_names)

  topic_name = each.key

  kafka_cluster {
    id = confluent_kafka_cluster.cluster.id
  }
  credentials {
    key    = confluent_api_key.kafka_api_key.id
    secret = confluent_api_key.kafka_api_key.secret
  }
  rest_endpoint = confluent_kafka_cluster.cluster.rest_endpoint
  config = {
    "cleanup.policy"      = "delete"
    "delete.retention.ms" = "86400000"
    "retention.ms"        = "604800000"
  }

  depends_on = [
    confluent_role_binding.kafka_cluster_admin
  ]
}

//------------------------------------------------
// Create KSQL cluster for querying

resource "confluent_service_account" "ksql_sa" {
  display_name = "ksql_sa"
  description  = "Service account that the ksqlDB cluster uses to talk to the Kafka cluster"
}

resource "confluent_role_binding" "ksql_sa_cluster_role" {
  principal   = "User:${confluent_service_account.ksql_sa.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.cluster.rbac_crn
}

resource "confluent_role_binding" "ksql_sa_sr_role" {
  principal   = "User:${confluent_service_account.ksql_sa.id}"
  role_name   = "ResourceOwner"
  crn_pattern = format("%s/%s", confluent_schema_registry_cluster.essentials.resource_name, "subject=*")
}

resource "confluent_ksql_cluster" "ksql_cluster" {
  display_name = "ksql_demo"
  csu          = 1
  kafka_cluster {
    id = confluent_kafka_cluster.cluster.id
  }
  credential_identity {
    id = confluent_service_account.ksql_sa.id
  }
  environment {
    id = confluent_environment.demo.id
  }
  depends_on = [
    confluent_role_binding.ksql_sa_cluster_role,
    confluent_schema_registry_cluster.essentials
  ]
}