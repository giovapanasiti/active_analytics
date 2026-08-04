class HomeController < ApplicationController
  def index
  end

  # Reproduction page for the flush-transport bug: a big enough DOM that the
  # serialized seq-0 snapshot batch exceeds the 64KB fetch-keepalive /
  # sendBeacon body cap, which used to be silently dropped (see
  # tasks/hotjar-alternative-spec.md "Flush transport").
  def big
  end
end
