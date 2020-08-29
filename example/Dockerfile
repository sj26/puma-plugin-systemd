# Must be built from parent directory so that it can be added to the container
# docker -t puma-plugin-systemd -f example/Dockerfile .

FROM fedora

RUN dnf -y install ruby ruby-devel redhat-rpm-config && \
    dnf -y groupinstall "Development tools"

WORKDIR /example

ADD ./etc/ /etc/
RUN systemctl enable puma

ADD . /example
ENV BUNDLE_SILENCE_ROOT_WARNING=true
RUN gem install bundler && \
  bundle install && \
  bundle binstubs puma

EXPOSE 9292
EXPOSE 9393

CMD /sbin/init
