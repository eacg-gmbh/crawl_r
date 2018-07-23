FROM        959013096341.dkr.ecr.eu-central-1.amazonaws.com/versioneye-core:1.0.2
MAINTAINER  Robert Reiz <reiz@versioneye.com>

# Install the AWS CLI
RUN apt-get update && apt-get -y install python python-dev python-pip python-setuptools groff less curl zip unzip && cd /tmp && \
    curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" \
    -o "awscli-bundle.zip" && \
    unzip awscli-bundle.zip && \
    ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws && \
    rm awscli-bundle.zip && rm -rf awscli-bundle

RUN rm -Rf /app; \
    mkdir /app

ADD . /app

RUN cp /app/supervisord.conf /etc/supervisord.conf; \
    cd /app/ && bundle install; \
    chmod +x /app/worker.sh /app/scheduler.sh

CMD /usr/bin/supervisord -c /etc/supervisord.conf
