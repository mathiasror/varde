package com.example.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Minimal Spring Boot web app for the varde-jre example.
 *
 * <p>{@code @SpringBootApplication} enables auto-configuration and component
 * scanning; {@code @RestController} makes this class a web controller too, so a
 * GET on "/" returns the plain string below. The e2e check asserts the response
 * body contains "varde ok".
 *
 * <p>The Java packages/imports are unchanged in Spring Boot 4.x
 * ({@code org.springframework.boot.SpringApplication} and
 * {@code org.springframework.boot.autoconfigure.SpringBootApplication}), but
 * the Gradle starter was renamed in 4.0: build.gradle depends on
 * {@code spring-boot-starter-webmvc}, not the deprecated
 * {@code spring-boot-starter-web}.
 */
@SpringBootApplication
@RestController
public class DemoApplication {

    public static void main(String[] args) {
        SpringApplication.run(DemoApplication.class, args);
    }

    @GetMapping("/")
    String home() {
        return "varde ok";
    }
}
