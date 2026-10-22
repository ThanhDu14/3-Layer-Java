package com.dpt.demo;

import java.net.InetAddress;
import java.net.UnknownHostException;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.info.BuildProperties;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ModelAttribute;

/**
 * Every page shows which app version and which Tomcat host served it,
 * so the demo can show load balancing, failover and rolling deploys.
 */
@ControllerAdvice
public class GlobalModelAdvice {

	private final String appVersion;

	private final String servedBy;

	public GlobalModelAdvice(ObjectProvider<BuildProperties> buildProperties) {
		BuildProperties build = buildProperties.getIfAvailable();
		this.appVersion = build != null ? build.getVersion() : "dev";
		this.servedBy = hostname();
	}

	@ModelAttribute("appVersion")
	public String appVersion() {
		return appVersion;
	}

	@ModelAttribute("servedBy")
	public String servedBy() {
		return servedBy;
	}

	private static String hostname() {
		try {
			return InetAddress.getLocalHost().getHostName();
		} catch (UnknownHostException ex) {
			return "unknown";
		}
	}
}
