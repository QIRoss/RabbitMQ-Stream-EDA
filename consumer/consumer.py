import pika
from streamz import Stream

def callback(ch, method, properties, body):
    """Callback function when a message is received."""
    stream.emit(body.decode())

def consume_message():
    connection = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
    channel = connection.channel()

    channel.queue_declare(queue='input_queue')

    channel.basic_consume(queue='input_queue', on_message_callback=callback, auto_ack=True)
    print(' [*] Waiting for messages. To exit press CTRL+C')
    channel.start_consuming()

stream = Stream()

stream.map(lambda message: message.upper()).sink(lambda msg: print(f"Processed message: {msg}"))

if __name__ == '__main__':
    consume_message()
