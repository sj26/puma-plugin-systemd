# Must be built from parent directory so that it can be added to the container
# docker -t puma-plugin-systemd -f example/Dockerfile .

FROM fedora

RUN dnf -y install ruby ruby-devel redhat-rpm-config && \
    dnf -y groupinstall "Development tools"

WORKDIR /puma-plugin-systemd

ADD ./example/etc/ /etc/
RUN systemctl enable puma

ADD . /puma-plugin-systemd
ENV BUNDLE_SILENCE_ROOT_WARNING=true
RUN gem install bundler && \
  bundle install && \
  bundle binstubs puma

CMD /sbin/init
