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

resource "confluent_schema" "topic_schema" {
  for_each = toset(local.source_topic_names)
  schema_registry_cluster {
    id = confluent_schema_registry_cluster.essentials.id
  }
  credentials {
    key    = confluent_api_key.producer_sr_api_key.id
    secret = confluent_api_key.producer_sr_api_key.secret
  }
  rest_endpoint = confluent_schema_registry_cluster.essentials.rest_endpoint

  subject_name = "${each.key}-value"
  format = "JSON"
  schema = file("${each.key}_schema.json")
}

//------------------------------------------------
// Define service account with limited access to just the topic that is needed

resource "confluent_service_account" "producer_sa" {
  display_name = "producer_sa"
  description  = "Service account to manage producer access"
}

resource "confluent_role_binding" "producer_cluster_admin" {
  principal   = "User:${confluent_service_account.producer_sa.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.cluster.rbac_crn
}

resource "confluent_kafka_acl" "describe_basic_cluster" {
  kafka_cluster {
    id = confluent_kafka_cluster.cluster.id
  }
  rest_endpoint = confluent_kafka_cluster.cluster.rest_endpoint
  credentials {
    key    = confluent_api_key.kafka_api_key.id
    secret = confluent_api_key.kafka_api_key.secret
  }

  resource_type = "CLUSTER"
  resource_name = "kafka-cluster"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.producer_sa.id}"
  host          = "*"
  operation     = "DESCRIBE"
  permission    = "ALLOW"
}

resource "confluent_kafka_acl" "describe_on_topic" {
  for_each = toset(local.source_topic_names)

  kafka_cluster {
    id = confluent_kafka_cluster.cluster.id
  }
  rest_endpoint = confluent_kafka_cluster.cluster.rest_endpoint
  credentials {
    key    = confluent_api_key.kafka_api_key.id
    secret = confluent_api_key.kafka_api_key.secret
  }

  resource_type = "TOPIC"
  resource_name = each.key
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.producer_sa.id}"
  host          = "*"
  operation     = "DESCRIBE"
  permission    = "ALLOW"
}

resource "confluent_kafka_acl" "write_on_topic" {
  for_each = toset(local.source_topic_names)

  kafka_cluster {
    id = confluent_kafka_cluster.cluster.id
  }
  rest_endpoint = confluent_kafka_cluster.cluster.rest_endpoint
  credentials {
    key    = confluent_api_key.kafka_api_key.id
    secret = confluent_api_key.kafka_api_key.secret
  }

  resource_type = "TOPIC"
  resource_name = each.key
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.producer_sa.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
}

resource "confluent_api_key" "producer_kafka_api_key" {
  display_name = "producer-kafka-api-key"
  description  = "Kafka API key that is owned by '${confluent_service_account.producer_sa.display_name}' service account"
  owner {
    id          = confluent_service_account.producer_sa.id
    api_version = confluent_service_account.producer_sa.api_version
    kind        = confluent_service_account.producer_sa.kind
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
    confluent_kafka_acl.describe_basic_cluster,
    confluent_kafka_acl.write_on_topic
  ]
}

resource "confluent_service_account" "sr_sa" {
  display_name = "sr_sa"
  description  = "Service account to manage schema registry access"
}

resource "confluent_role_binding" "environment_admin" {
  principal   = "User:${confluent_service_account.sr_sa.id}"
  role_name = "EnvironmentAdmin"
  crn_pattern = confluent_environment.demo.resource_name
  // role_name   = "CloudSchemaRegistryAdmin"
  // crn_pattern = confluent_schema_registry_cluster.essentials.resource_name
}

resource "confluent_api_key" "producer_sr_api_key" {
  display_name = "producer-sr-api-key"
  description  = "Schema Registry API key that is owned by '${confluent_service_account.sr_sa.display_name}' service account"
  owner {
    id          = confluent_service_account.sr_sa.id
    api_version = confluent_service_account.sr_sa.api_version
    kind        = confluent_service_account.sr_sa.kind
  }

  managed_resource {
    id          = confluent_schema_registry_cluster.essentials.id
    api_version = confluent_schema_registry_cluster.essentials.api_version
    kind        = confluent_schema_registry_cluster.essentials.kind

    environment {
      id = confluent_environment.demo.id
    }
  }
}

//------------------------------------------------
// Display some outputs here to use the service accounts

output "kafka_endpoint" {
  value = confluent_kafka_cluster.cluster.bootstrap_endpoint
}

output "kafka_api_key" {
  value = confluent_api_key.producer_kafka_api_key.id
}

output "kafka_api_secret" {
  value = confluent_api_key.producer_kafka_api_key.secret
  sensitive = true
}

output "sr_endpoint" {
  value = confluent_schema_registry_cluster.essentials.rest_endpoint
}

output "sr_key" {
  value = confluent_api_key.producer_sr_api_key.id
}

output "sr_secret" {
  value = confluent_api_key.producer_sr_api_key.secret
  sensitive = true
}

