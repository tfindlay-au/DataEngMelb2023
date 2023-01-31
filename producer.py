# --------------------
# Data Generator
#
# Purpose:
#   Generate data for Apache Kafka
#
# Requires:
#   Faker
#   kafka

import logging
import random
import uuid
import json

from faker import Faker
from confluent_kafka import Producer
from confluent_kafka.serialization import SerializationContext, MessageField
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.json_schema import JSONSerializer

BROKER = "<KafkaBrokerURL>"
SASL_USERNAME = "<KafkaAPIKey>"
SASL_PASSWORD = "<KafkaAPISecret>"

SR_BROKER = "<SchemaRegistryURL>"
SR_SASL_USERNAME = "<SchemaRegistryKey>"
SR_SASL_PASSWORD = "<SchemaRegistrySecret>"

TOPIC = "input_topic"

logging.basicConfig(level=logging.INFO)


def make_event():
    fake = Faker()
    event_types = ["CLICK", "SALE", "RETURN", "EXCHANGE"]
    data = {
        "field1": random.choice(event_types),
        "field2": fake.ascii_company_email(),
        "field3": str(uuid.uuid4())
    }
    return data


def event_to_dict(event, ctx):
    return event


def delivery_callback(err, msg):
    if err:
        logging.error('ERROR: Message failed delivery: {}'.format(err))
    else:
        logging.info("Produced event to topic {topic}:{partition}:{offset} value = {value}".format(
            topic=msg.topic(), partition=msg.partition(), offset=msg.offset(), value=msg.value()))


def main():

    logging.info("Starting...")

    config = {
        "bootstrap.servers": BROKER,
        "security.protocol": "SASL_SSL",
        "sasl.mechanism": "PLAIN",
        "sasl.username": SASL_USERNAME,
        "sasl.password": SASL_PASSWORD,
    }

    producer = Producer(config)

    # Configure Schema Registry instance to use
    schema_registry_config = {
        'url': SR_BROKER,
        'basic.auth.user.info': f"{SR_SASL_USERNAME}:{SR_SASL_PASSWORD}"
    }
    schema_registry_client = SchemaRegistryClient(schema_registry_config)

    # Read JSONSchema definition from file
    with open("input-topic_schema.json", 'r') as infile:
        schema_string = json.dumps(json.load(infile))

    # Configure Serializer to use Schema /w Schema Registry
    json_serializer = JSONSerializer(schema_registry_client=schema_registry_client,
                                     schema_str=schema_string,
                                     to_dict=event_to_dict)

    # Generate records and publish to Kafka
    for i in range(0, 10):
        record = make_event()
        producer.produce(topic=TOPIC,
                         value=json_serializer(record, SerializationContext(TOPIC, MessageField.VALUE)),
                         callback=delivery_callback)

    # block until all async messages are sent
    producer.flush()


if __name__ == "__main__":
    main()
